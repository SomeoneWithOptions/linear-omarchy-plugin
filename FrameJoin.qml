import QtQuick
import QtQuick.Shapes

// Concave join between desktop frame and attached drawer.
// Feathered radial + CurveRenderer for crisp antialiased curve.
Shape {
  id: root

  property int cornerRadius: 18
  property color frameColor: "#000000"

  width: cornerRadius
  height: cornerRadius
  preferredRendererType: Shape.CurveRenderer

  ShapePath {
    strokeWidth: 0
    fillGradient: RadialGradient {
      centerX: 0
      centerY: root.height
      centerRadius: root.width
      focalX: centerX
      focalY: centerY
      GradientStop { position: 0.0; color: "transparent" }
      GradientStop { position: 0.98; color: "transparent" }
      GradientStop { position: 1.0; color: root.frameColor }
    }
    PathSvg {
      path: "M 0 0 L " + root.width + " 0 L " + root.width + " " + root.height
        + " L 0 " + root.height + " Z"
    }
  }
}
