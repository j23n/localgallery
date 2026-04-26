import SwiftUI
import WidgetKit

@main
struct LocalGalleryWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MemoriesWidget()
        FolderWidget()
        TagsWidget()
    }
}
