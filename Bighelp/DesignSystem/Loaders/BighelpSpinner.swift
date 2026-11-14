import SwiftUI

/// A small loader for rows and buttons: the lifter, laid out at `size` (drawn a little
/// larger so it reads like a spinner of that size). The kit's colors unless a color is
/// given. At these sizes he's the still mark (DESIGN.md › Lifter).
struct BighelpSpinner: View {
    var size: CGFloat = 12
    var color: Color?

    var body: some View {
        BighelpLifterView(motion: .idle, size: size * 1.25, tint: color)
            .frame(width: size, height: size)
    }
}
