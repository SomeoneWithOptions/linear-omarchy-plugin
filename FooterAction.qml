import QtQuick
import qs.Commons
import qs.Ui

// One footer affordance: a keycap plus the action it performs, clickable as
// a single target.
//
// Both footer rows are the same shape, so the metrics — cap padding, cap
// height, gap to the label — live here once instead of being restated (and
// drifting) at each call site. The cap sizes itself from its own text rather
// than a fixed pixel height, so it tracks `[font] base-size` and never clips
// a descender on a large-font theme.
Item {
  id: root

  property string keyLabel: ""
  property string label: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  // Primary rows carry the accent fill and a full-strength label; secondary
  // rows stay quiet until hovered. `active` gates the click and drops a
  // primary row back to the idle chrome so a disabled action never looks
  // pressable.
  property bool primary: false
  property bool active: true

  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property bool hot: mouse.containsMouse && active
  readonly property bool emphasized: primary && active

  signal triggered()

  implicitWidth: row.implicitWidth
  implicitHeight: row.implicitHeight

  Row {
    id: row
    spacing: Style.space(7)

    BorderSurface {
      anchors.verticalCenter: parent.verticalCenter
      implicitWidth: capText.implicitWidth + Style.space(12)
      implicitHeight: capText.implicitHeight + Style.space(6)
      // Keycaps read as caps, not as cards: clamp to a tight radius so a
      // theme with heavy Hyprland rounding doesn't turn them into pills.
      radius: Math.max(0, Math.min(Style.cornerRadius, Style.space(4)))

      color: !root.active
        ? Style.normalFillFor(root.foreground, Color.accent)
        : (root.emphasized
          ? (root.hot ? Style.pressedFillFor(root.foreground, Color.accent) : Style.selectedFillFor(root.foreground, Color.accent))
          : (root.hot ? Style.hoverFillFor(root.foreground, Color.accent) : Style.normalFillFor(root.foreground, Color.accent)))

      borderSpec: Border.controlSpec(
        !root.active
          ? "normal"
          : (root.emphasized
            ? (root.hot ? "focus" : "selected")
            : (root.hot ? "hover-cursor" : "normal")),
        root.foreground, Color.accent)

      Behavior on color { ColorAnimation { duration: 60 } }

      Text {
        id: capText
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: root.keyLabel
        color: root.active || root.emphasized ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: root.label
      color: root.emphasized || root.hot ? root.foreground : root.dim
      opacity: root.emphasized ? 0.9 : 0.65
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption

      Behavior on opacity { NumberAnimation { duration: 60 } }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    // Without this `containsMouse` only reports while a button is held, so
    // every hover state above would be dead.
    hoverEnabled: true
    cursorShape: root.active ? Qt.PointingHandCursor : Qt.ArrowCursor
    enabled: root.active
    onClicked: root.triggered()
  }
}
