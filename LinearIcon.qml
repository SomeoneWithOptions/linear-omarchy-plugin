import QtQuick
import qs.Commons

// The Linear mark, drawn from primitives rather than an SVG so it stays crisp
// in a bar slot at any font scale (same approach as TailscaleIcon).
//
// Three parallel chords of increasing then decreasing length, rotated 45°.
// Rotating the whole stack keeps the geometry to one transform instead of
// three positioned-and-rotated bars.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real thickness: Math.max(1.5, iconSize * 0.15)
  readonly property real barGap: Math.max(1, iconSize * 0.15)
  readonly property real longBar: iconSize * 0.95
  readonly property real shortBar: iconSize * 0.62

  Column {
    anchors.centerIn: parent
    rotation: -45
    spacing: root.barGap

    Bar { barWidth: root.shortBar }
    Bar { barWidth: root.longBar }
    Bar { barWidth: root.shortBar }
  }

  component Bar: Rectangle {
    property real barWidth: 0
    anchors.horizontalCenter: parent.horizontalCenter
    width: barWidth
    height: root.thickness
    radius: height / 2
    color: root.color
  }
}
