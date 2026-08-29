# LAXIFY — DESIGN.md

## 1. Visual Theme & Atmosphere
Чёрно-белый editorial-минимализм в духе Apple/Linear. Чистый чёрный (#000), белая типографика, тонкие серые линии. Никаких цветов — контраст решает всё. Атмосфера: премиальный, строгий, «музыкальный».
Ключевые слова: monochrome, editorial, high-contrast, glass, spacious.

## 2. Color Palette & Roles
```css
:root {
  --bg: #000000;            /* основной фон */
  --bg-soft: #0a0a0a;       /* карточки, секции */
  --bg-elev: #111111;       /* приподнятые поверхности */
  --line: rgba(255,255,255,0.10);   /* границы, RGB для rgba() */
  --line-strong: rgba(255,255,255,0.22);
  --text: #f5f5f5;          /* основной текст */
  --text-dim: #9b9b9b;      /* вторичный текст */
  --text-faint: #5c5c5c;    /* подписи, футер */
  --white: #ffffff;         /* акцент: кнопки, заливки */
}
```
Единственный «акцент» — чистый белый (кнопки, подсветки). Серые ступени — единственная градация.

## 3. Typography Rules
```css
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&display=swap&subset=cyrillic');
```
- Family: `"Inter", -apple-system, "Segoe UI", sans-serif` (кириллица поддерживается)
- H1: clamp(44px, 8vw, 96px) / 900 / letter-spacing -0.04em
- H2: clamp(30px, 5vw, 56px) / 800 / -0.03em
- Body: 17px / 400 / 1.65 / --text-dim
- Eyebrow: 13px / 600 / uppercase / letter-spacing 0.22em / --text-dim
- Запрещены: системный Times, декоративные шрифты, курсив в заголовках

## 4. Component Stylings
```css
.btn-primary { background:#fff; color:#000; border-radius:999px; padding:16px 32px; font-weight:700; transition: transform .25s, box-shadow .25s; }
.btn-primary:hover { transform: translateY(-2px); box-shadow: 0 12px 40px rgba(255,255,255,.18); }
.btn-primary:active { transform: translateY(0) scale(.98); }
.btn-primary:focus-visible { outline: 2px solid #fff; outline-offset: 3px; }
.btn-ghost { background:transparent; color:#fff; border:1px solid var(--line-strong); border-radius:999px; padding:16px 32px; transition: background .25s, border-color .25s; }
.btn-ghost:hover { background: rgba(255,255,255,.08); border-color: rgba(255,255,255,.45); }
.card { background: var(--bg-soft); border: 1px solid var(--line); border-radius: 24px; transition: border-color .3s, transform .3s; }
.card:hover { border-color: var(--line-strong); transform: translateY(-4px); }
.nav-link { color: var(--text-dim); transition: color .2s; }
.nav-link:hover, .nav-link:focus-visible { color: #fff; }
a, button { outline-offset: 3px; }
a:focus-visible, button:focus-visible { outline: 2px solid #fff; border-radius: 8px; }
```

## 5. Layout Principles
- Контейнер: max-width 1160px, паддинг 24px
- Секции: padding 120px 0 (desktop) / 72px 0 (mobile)
- Сетка фич: bento 12 колонок, gap 16px
- Радиусы: 24px карточки, 999px кнопки

## 6. Depth & Elevation
Тени почти не используются — глубину дают тонкие границы и слои фона.
```css
--shadow-glow: 0 0 120px rgba(255,255,255,0.08); /* только hero-телефон */
box-shadow: 0 30px 80px rgba(0,0,0,0.6);         /* плавающие скрины */
```

## 7. Animation & Interaction — уровень L2+
- Hero: load- stagger reveal (clip-path + translateY, CSS keyframes, 1 раз)
- Marquee: бесконечная бегущая строка, чистый CSS translateX
- Scroll reveal: IntersectionObserver → .in-view (opacity + translateY 28px, stagger по индексу)
- Параллакс: hero-телефон translateY по скроллу (rAF-троттлинг)
- SpotlightCard: --mx/--my + radial-gradient ::before (rAF)
- Навигация: после 40px скролла — фон rgba(0,0,0,.7) + blur(14px) + нижняя граница
- Счётчики: анимация чисел при входе в вьюпорт
- `prefers-reduced-motion: reduce` → все анимации/transition отключены, всё видимo сразу

## 8. Do's and Don'ts
**Do:** whitespace 120px+; контраст текста ≥ 7:1; тонкие линии 1px; крупные заголовки; моно-иконки (SVG stroke); плавность 0.25–0.5s cubic-bezier(.22,.61,.36,1).
**Don't:**
1. Никаких цветов кроме чёрно-белой гаммы (даже синие ссылки)
2. Никаких emoji в UI
3. Не использовать тени как основной инструмент глубины
4. Не ставить blur > 14px на большие площади
5. Не анимировать layout-свойства (top/left/width) — только transform/opacity
6. Не гнать marquee быстрее 40s за цикл
7. Не блокировать скролл (никаких scroll-jacking)
8. Не использовать картинки-плейсхолдеры с чистыми заливками
9. Не превращать карточки в пёстрые градиенты — максимум rgba(255,255,255,.06)

## 9. Responsive Behavior
- ≤ 960px: bento → 1-2 колонки, hero-телефон по центру, nav-links скрыты (кнопки остаются)
- ≤ 600px: H1 44px, секции 72px, карточки full-width, тач-таргеты ≥ 44px
- Горизонтальный overflow запрещён; marquee не выходит за экран
