import WidgetKit
import SwiftUI

@main
struct BlueDiveWidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        ManualDiveWidget()
        BluetoothDiveWidget()
        DiveCountWidget()
        DiverStatsWidget()
    }
}
