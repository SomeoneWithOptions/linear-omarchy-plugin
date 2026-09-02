import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button + one-field popup for filing a Linear issue.
//
// The panel is deliberately thin: it collects a title and hands it to
// bin/omarchy-linear-issue-create detached. The helper owns the network call
// and both notifications, so the popup can close the instant Enter lands and
// the shell never waits on the Linear API.
Panel {
  id: root
  moduleName: "andres.linear"
  ipcTarget: "andres.linear"

  property string draftTitle: ""
  property string targetLabel: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.55)

  // Resolved against this file's directory, so the helper is found wherever
  // `omarchy plugin add` cloned the plugin.
  readonly property string helperPath: String(Qt.resolvedUrl("bin/omarchy-linear-issue-create")).replace(/^file:\/\//, "")

  readonly property bool canSubmit: draftTitle.trim() !== ""

  // `omarchy bar set` writes layout-entry values as strings, so a stored
  // "false" arrives here as a truthy string. Accept either form.
  readonly property bool frameStyleEnabled: {
    var value = setting("frameStyle", true)
    if (typeof value === "string") return value !== "false" && value !== "0" && value !== ""
    return value === true
  }

  function submit() {
    if (!canSubmit) return
    var title = draftTitle.trim()
    root.close()
    Quickshell.execDetached([root.helperPath, title])
  }

  // The destination is defined in config.lua, not in shell.json, so ask the
  // helper for it rather than keeping a second copy that can drift.
  function refreshTarget() { targetProc.running = true }

  Component.onCompleted: refreshTarget()

  onOpenedChanged: {
    if (!opened) return
    draftTitle = ""
    refreshTarget()
    Qt.callLater(function() { titleField.forceActiveFocus() })
  }

  Process {
    id: targetProc
    command: [root.helperPath, "--target"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.targetLabel = String(text || "").trim()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "New Linear issue"
    iconComponent: Component {
      Item {
        LinearIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.barForeground
        }
      }
    }
    onPressed: function(buttonCode) { root.toggle() }
  }

  // Pinned to the top-left corner rather than under its own icon, so the
  // capture field always opens in the same place no matter where the widget
  // sits in the bar.
  FramePanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: titleField
    pinEdge: "left"
    frameStyle: root.frameStyleEnabled
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(320))

    // The title field owns the keyboard while it has focus, so the catcher's
    // vim-style navigation never eats characters typed into it.
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: titleField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(14)

        PanelHero {
          width: parent.width
          title: "New issue"
          meta: root.targetLabel
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            LinearIcon {
              iconSize: Style.font.display
              color: root.foreground
            }
          }
        }

        TextField {
          id: titleField
          width: parent.width
          foreground: root.foreground
          placeholderText: "Issue title"
          text: root.draftTitle
          onTextChanged: root.draftTitle = text
          onAccepted: root.submit()
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              root.close()
              event.accepted = true
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            text: root.canSubmit ? "Enter to create" : "Type a title to create"
            color: root.canSubmit ? root.foreground : root.dim
            opacity: root.canSubmit ? 0.85 : 1
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            textFormat: Text.PlainText
            text: "·"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            textFormat: Text.PlainText
            text: "Esc to cancel"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }
}
