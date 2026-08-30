import SwiftUI
import WidgetKit

@main
struct LaxifyWidgetBundle: WidgetBundle {
    var body: some Widget {
        LaxifyLogoWidget()
        NowPlayingLiveActivity()
    }
}
