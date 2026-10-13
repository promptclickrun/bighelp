import SwiftUI

/// A small loader for rows and buttons: the Noodle's loader, laid out at `size` (the b
/// is drawn a little larger so it reads like a spinner of that size). The kit's Ember
/// unless a color is given.
struct BighelpSpinner: View {
    var size: CGFloat = 12
    var color: Color?

    var body: some View {
        BighelpNoodleView(motion: .loader, size: size * 1.25, tint: color)
            .frame(width: size, height: size)
    }
}
