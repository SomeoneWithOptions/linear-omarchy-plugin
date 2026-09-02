import QtQuick
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
  // PanelHero tints its meta line at 1.4; the destination line sits in the
  // same visual tier, so it uses the same value rather than inventing one.
  readonly property color muted: Qt.darker(foreground, 1.4)

  // Resolved against this file's directory, so the helper is found wherever
  // `omarchy plugin add` cloned the plugin.
  readonly property string helperPath: String(Qt.resolvedUrl("bin/omarchy-linear-issue-create")).replace(/^file:\/\//, "")

  readonly property bool canSubmit: draftTitle.trim() !== ""

  // The bar sizes each slot from its item's implicit size, so without these
  // the button renders into a zero-width slot and the icon never appears.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // `omarchy bar set` writes layout-entry values as strings, so a stored
  // "false" arrives here as a truthy string. Accept either form.
  readonly property bool frameStyleEnabled: {
    var value = setting("frameStyle", true)
    if (typeof value === "string") return value !== "false" && value !== "0" && value !== ""
    return value === true
  }

  // Screen corner the capture field opens in. Accepts "top-left", "top-right",
  // "bottom-left" and "bottom-right"; spaces and underscores are tolerated so a
  // hand-edited "Top Left" still lands somewhere sane. Anything unrecognised
  // falls back to the default top-left.
  readonly property string panelPosition: {
    var value = String(setting("panelPosition", "top-left")).trim().toLowerCase().replace(/[ _]+/g, "-")
    var known = ["top-left", "top-right", "bottom-left", "bottom-right"]
    return known.indexOf(value) >= 0 ? value : "top-left"
  }
  readonly property string panelPinEdge: panelPosition.indexOf("right") >= 0 ? "right" : "left"
  readonly property string panelPinVerticalEdge: panelPosition.indexOf("bottom") === 0 ? "bottom" : "top"

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
          iconSize: Style.space(12)
          color: root.barForeground
        }
      }
    }
    onPressed: function(buttonCode) { root.toggle() }
  }

  // Pinned to a screen corner rather than under its own icon, so the capture
  // field always opens in the same place no matter where the widget sits in the
  // bar. Which corner is the `panelPosition` setting.
  FramePanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: titleField
    pinEdge: root.panelPinEdge
    pinVerticalEdge: root.panelPinVerticalEdge
    // Keyboard focus wins over surviving a stray click. The two cannot be had
    // at once: only a Wayland input region under the pointer keeps the
    // keyboard, because Hyprland re-runs focus-under-cursor when the panel
    // drops from its Exclusive focus prime to OnDemand (Hyprland
    // LayerSurface.cpp: WASEXCLUSIVE && now ON_DEMAND -> simulateMouseMovement).
    // A card-only input region is not under the pointer, so the panel handed
    // the keyboard straight back to the window behind it ~75ms after opening
    // and SUPER+SHIFT+L typed into whatever was focused before. The
    // full-screen region keeps the keyboard, and its cost is that a click
    // outside the card lands on the panel and dismisses it.
    dismissOnOutsideClick: true
    frameStyle: root.frameStyleEnabled
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(320))

    // The title field owns the keyboard while it has focus, so the catcher's
    // vim-style navigation never eats characters typed into it.
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: titleField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // Rhythm, top to bottom: hero, field group, footer group. The gaps
      // *between* those three are the panel's section spacing; the gaps
      // *inside* each are tighter, so the eye groups the field with its
      // destination and the rule with the footer it introduces.
      Column {
        id: column
        width: parent.width
        spacing: Style.space(14)

        PanelHero {
          id: hero
          width: parent.width
          title: "New issue"
          meta: "Linear"
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            LinearIcon {
              iconSize: Style.font.display
              color: root.foreground
            }
          }
        }

        // What you type and where it lands, read as one unit.
        Column {
          width: parent.width
          spacing: Style.space(6)

          // The field is the reason the panel exists, so it outranks the hero
          // title in size and gets the roomiest padding on the card.
          TextField {
            id: titleField
            width: parent.width
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            horizontalPadding: Style.space(12)
            verticalPadding: Style.space(10)
            placeholderText: "Issue title…"
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

          // "Team › Project" from config.lua. It lives on its own line rather
          // than in the hero's detail pill because a pill sizes to its text
          // and cannot elide — a long project name would have pushed the
          // title out of the card. It also arrives a beat after the panel
          // opens, so hide the line until it does instead of reserving a gap.
          Text {
            width: parent.width
            visible: root.targetLabel !== ""
            textFormat: Text.PlainText
            text: "→ " + root.targetLabel
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        // The rule introduces the footer, so it sits closer to it than to the
        // field above.
        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
            strength: 0.1
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(submitAction.implicitHeight, cancelAction.implicitHeight)

            FooterAction {
              id: submitAction
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              keyLabel: "↵ Enter"
              label: root.canSubmit ? "Create issue" : "Type a title to create"
              primary: true
              active: root.canSubmit
              foreground: root.foreground
              fontFamily: root.fontFamily
              onTriggered: root.submit()
            }

            FooterAction {
              id: cancelAction
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              keyLabel: "Esc"
              label: "Cancel"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onTriggered: root.close()
            }
          }
        }
      }
    }
  }
}
