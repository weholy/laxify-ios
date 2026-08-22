"""Listening statistics, by month and overall.

Built from the play log rather than from counters, so the numbers can be
sliced any way later without having decided in advance. Every figure is
computed from `listening_events`, which records how much of a track was
actually heard — a skip after three seconds does not count the same as a
full listen.
"""

from datetime import UTC, datetime, timedelta

from fastapi import APIRouter, Query
from pydantic import BaseModel
from sqlalchemy import and_, desc, distinct, func, select

from app.api.deps import CurrentUser, SessionDep
from app.models import ListeningEvent, TrackSnapshot

router = APIRouter(prefix="/replay", tags=["replay"])

# Below this a play is a skip, and counting it would flatter every number on
# the screen.
MEANINGFUL_SECONDS = 30

MONTH_NAMES = [
    "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь",
    "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь",
]

SHORT_MONTHS = ["Янв", "Фев", "Мар", "Апр", "Май", "Июн", "Июл", "Авг", "Сен", "Окт", "Ноя", "Дек"]


class TopArtist(BaseModel):
    id: str | None
    name: str
    artwork_url: str | None
    minutes: int
    plays: int


class TopTrack(BaseModel):
    id: str
    title: str
    artist_name: str
    artwork_url: str | None
    plays: int
    minutes: int


class GenreShare(BaseModel):
    name: str
    plays: int


class Period(BaseModel):
    """One selectable span — a month, or everything."""

    id: str
    title: str
    short_title: str
    is_current: bool = False


class ReplaySummary(BaseModel):
    period: Period
    total_minutes: int
    total_plays: int
    distinct_tracks: int
    distinct_artists: int
    top_artists: list[TopArtist]
    top_tracks: list[TopTrack]
    genres: list[GenreShare]
    # Days with any listening at all, and the longest unbroken run of them —
    # the shape of a habit rather than its size.
    active_days: int
    longest_streak_days: int


def _bounds(period_id: str) -> tuple[datetime | None, datetime | None]:
    """Turns a period id into a range. `all` has no bounds."""
    if period_id == "all":
        return None, None

    year, month = (int(part) for part in period_id.split("-"))
    start = datetime(year, month, 1, tzinfo=UTC)
    end = datetime(year + (month // 12), (month % 12) + 1, 1, tzinfo=UTC)
    return start, end


def _title(period_id: str) -> tuple[str, str]:
    if period_id == "all":
        return "За всё время", "Всё"

    year, month = (int(part) for part in period_id.split("-"))
    name = MONTH_NAMES[month - 1]
    # The year is only worth saying when it is not this one.
    if year != datetime.now(UTC).year:
        return f"{name} {year}", SHORT_MONTHS[month - 1]
    return name, SHORT_MONTHS[month - 1]


def _range_filter(user_id, period_id: str):
    start, end = _bounds(period_id)
    clauses = [
        ListeningEvent.user_id == user_id,
        ListeningEvent.seconds_played >= MEANINGFUL_SECONDS,
    ]
    if start is not None:
        clauses.append(ListeningEvent.played_at >= start)
    if end is not None:
        clauses.append(ListeningEvent.played_at < end)
    return and_(*clauses)


@router.get("/periods", response_model=list[Period])
async def periods(user: CurrentUser, session: SessionDep) -> list[Period]:
    """Months this listener actually has something in, newest first.

    Offering every month of the year would mean tapping through empty
    screens; only months with listening in them are worth showing.
    """
    rows = (
        await session.execute(
            select(
                func.extract("year", ListeningEvent.played_at).label("y"),
                func.extract("month", ListeningEvent.played_at).label("m"),
            )
            .where(
                ListeningEvent.user_id == user.id,
                ListeningEvent.seconds_played >= MEANINGFUL_SECONDS,
            )
            .group_by("y", "m")
            .order_by(desc("y"), desc("m"))
            .limit(24)
        )
    ).all()

    today = datetime.now(UTC)
    result: list[Period] = []

    for year, month in rows:
        identifier = f"{int(year)}-{int(month):02d}"
        title, short = _title(identifier)
        result.append(
            Period(
                id=identifier,
                title=title,
                short_title=short,
                is_current=int(year) == today.year and int(month) == today.month,
            )
        )

    result.append(Period(id="all", title="За всё время", short_title="Всё"))
    return result


@router.get("", response_model=ReplaySummary)
async def summary(
    user: CurrentUser,
    session: SessionDep,
    period: str = Query("all", pattern=r"^(all|\d{4}-\d{2})$"),
    limit: int = Query(10, ge=3, le=25),
) -> ReplaySummary:
    where = _range_filter(user.id, period)
    title, short = _title(period)

    totals = (
        await session.execute(
            select(
                func.coalesce(func.sum(ListeningEvent.seconds_played), 0),
                func.count(ListeningEvent.id),
                func.count(distinct(ListeningEvent.track_id)),
                func.count(distinct(ListeningEvent.artist_id)),
            ).where(where)
        )
    ).one()

    seconds, plays, tracks, artists = totals

    # Distinct calendar days, which needs the timestamp truncated rather than
    # cast — counting distinct timestamps would count every play.
    active_days = (
        await session.scalar(
            select(func.count(distinct(func.date(ListeningEvent.played_at)))).where(where)
        )
    ) or 0

    top_artist_rows = (
        await session.execute(
            select(
                ListeningEvent.artist_id,
                func.coalesce(func.sum(ListeningEvent.seconds_played), 0).label("seconds"),
                func.count(ListeningEvent.id).label("plays"),
            )
            .where(where, ListeningEvent.artist_id.isnot(None))
            .group_by(ListeningEvent.artist_id)
            .order_by(desc("seconds"))
            .limit(limit)
        )
    ).all()

    top_track_rows = (
        await session.execute(
            select(
                ListeningEvent.track_id,
                func.coalesce(func.sum(ListeningEvent.seconds_played), 0).label("seconds"),
                func.count(ListeningEvent.id).label("plays"),
            )
            .where(where)
            .group_by(ListeningEvent.track_id)
            .order_by(desc("plays"), desc("seconds"))
            .limit(limit)
        )
    ).all()

    # One lookup for every snapshot the rows refer to, rather than one each.
    wanted_tracks = {row[0] for row in top_track_rows}
    wanted_artists = {row[0] for row in top_artist_rows}

    snapshots = {}
    if wanted_tracks or wanted_artists:
        rows = (
            await session.scalars(
                select(TrackSnapshot).where(
                    TrackSnapshot.track_id.in_(wanted_tracks | set())
                    | TrackSnapshot.artist_id.in_(wanted_artists | set())
                )
            )
        ).all()
        for snapshot in rows:
            snapshots.setdefault(snapshot.track_id, snapshot)

    by_artist: dict[str, TrackSnapshot] = {}
    for snapshot in snapshots.values():
        if snapshot.artist_id and snapshot.artist_id not in by_artist:
            by_artist[snapshot.artist_id] = snapshot

    top_artists = [
        TopArtist(
            id=artist_id,
            name=(by_artist.get(artist_id).artist_name if by_artist.get(artist_id) else "Исполнитель"),
            artwork_url=(by_artist.get(artist_id).cover_url if by_artist.get(artist_id) else None),
            minutes=int(artist_seconds // 60),
            plays=artist_plays,
        )
        for artist_id, artist_seconds, artist_plays in top_artist_rows
    ]

    top_tracks = [
        TopTrack(
            id=track_id,
            title=(snapshots.get(track_id).title if snapshots.get(track_id) else "Трек"),
            artist_name=(snapshots.get(track_id).artist_name if snapshots.get(track_id) else ""),
            artwork_url=(snapshots.get(track_id).cover_url if snapshots.get(track_id) else None),
            plays=track_plays,
            minutes=int(track_seconds // 60),
        )
        for track_id, track_seconds, track_plays in top_track_rows
    ]

    return ReplaySummary(
        period=Period(id=period, title=title, short_title=short),
        total_minutes=int(seconds // 60),
        total_plays=plays,
        distinct_tracks=tracks,
        distinct_artists=artists,
        top_artists=top_artists,
        top_tracks=top_tracks,
        genres=await _genres(session, where, limit=6),
        active_days=active_days,
        longest_streak_days=await _longest_streak(session, where),
    )


async def _genres(session, where, limit: int) -> list[GenreShare]:
    """What was listened to, by genre.

    Genre lives on the track snapshot rather than the play, so this joins
    across — tracks nobody has a snapshot for simply do not appear.
    """
    rows = (
        await session.execute(
            select(TrackSnapshot.genre, func.count(ListeningEvent.id).label("plays"))
            .join(TrackSnapshot, TrackSnapshot.track_id == ListeningEvent.track_id)
            .where(where, TrackSnapshot.genre.isnot(None), TrackSnapshot.genre != "")
            .group_by(TrackSnapshot.genre)
            .order_by(desc("plays"))
            .limit(limit)
        )
    ).all()

    return [GenreShare(name=name, plays=plays) for name, plays in rows]


async def _longest_streak(session, where) -> int:
    """The longest run of consecutive days with listening in it."""
    rows = (
        await session.execute(
            select(func.date(ListeningEvent.played_at).label("day"))
            .where(where)
            .group_by("day")
            .order_by("day")
        )
    ).all()

    if not rows:
        return 0

    ordered = [row[0] for row in rows if row[0] is not None]
    if not ordered:
        return 0
    longest = 1
    run = 1

    for previous, current in zip(ordered, ordered[1:]):
        if (current - previous) == timedelta(days=1):
            run += 1
            longest = max(longest, run)
        else:
            run = 1

    return longest


class ReplayBundle(BaseModel):
    """Everything the statistics screen opens with, in one answer."""

    periods: list[Period]
    current: ReplaySummary | None
    previous: ReplaySummary | None


@router.get("/bundle", response_model=ReplayBundle)
async def bundle(
    user: CurrentUser,
    session: SessionDep,
    limit: int = Query(10, ge=3, le=25),
) -> ReplayBundle:
    """Opens the screen in one round trip rather than three.

    The screen needs the months, this month's figures, and last month's to
    compare against. Asking for those in sequence meant three waits stacked
    end to end before anything could be drawn.
    """
    available = await periods(user=user, session=session)

    months = [period for period in available if period.id != "all"]
    opening = next((p for p in months if p.is_current), months[0] if months else None)

    if opening is None:
        return ReplayBundle(periods=available, current=None, previous=None)

    earlier = next((p for p in months if p.id != opening.id), None)

    current_summary = await summary(
        user=user, session=session, period=opening.id, limit=limit
    )
    previous_summary = (
        await summary(user=user, session=session, period=earlier.id, limit=limit)
        if earlier
        else None
    )

    return ReplayBundle(
        periods=available, current=current_summary, previous=previous_summary
    )
