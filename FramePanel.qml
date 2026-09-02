import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Layer-shell popup attached to a bar widget icon, designed for
// click-driven AND keyboard-driven panels (e.g. SUPER+CTRL+W summon).
//
// Built on PanelWindow with a brief WlrKeyboardFocus.Exclusive prime followed
// by OnDemand rather than PopupWindow (xdg-popup). The prime acquires focus
// both when the surface maps and when it reopens while still mapped for its
// fade-out. xdg-popups don't get that — they only receive keys after a
// click/hover routes focus through their parent surface — so keyboard-summoned
// popups fell flat without it.
//
// Exclusive would also grant map-time focus, but it makes Hyprland route
// *every* pointer event to the exclusive surface no matter which output
// the cursor is over, which leaves clicks on any other monitor unable to
// reach the dismissal surfaces below.
//
// API is a subset of Common.PopupCard: anchorItem, owner, bar, open,
// padding, margin, contentWidth/Height, centerOnBar, default contentItem.
// Missing on purpose (for now): triggerMode ("hover"), containsMouse.
//
// Positioning: full-screen layer-shell with the card placed inside at
// `cardOrigin`. We use the bar window's height/width for the perpendicular
// axis (away-from-bar) because mapToItem on the anchor returns
// bar-content-relative coords with internal layout offsets baked in
// (e.g. ~13px from the bar's vertical centering of its widget row). The
// parallel axis (along-the-bar) uses the anchor's content x/y since the
// bar spans full screen on that axis.
//
// Outside-click dismissal: an overlay MouseArea catches clicks, with the
// QsWindow.mask subtracting the bar strip so clicks on the bar still
// reach the bar widgets (activePopout coordinator hands off to another
// popup if the user clicks a different bar icon). Set
// `dismissOnOutsideClick: false` for a panel that survives clicking away and
// only closes on Esc (or the bar icon / IPC); its input region then covers
// the card alone, so clicks elsewhere reach and focus the window below.
PanelWindow {
  id: root

  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property int margin: Style.gapsOut
  property int padding: Style.spacing.popupPadding
  property int contentWidth: Style.space(280)
  property int contentHeight: Style.space(200)
  property var borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
  property bool centerOnBar: false
  property bool open: false
  // Frame styling is the default: the card overlaps the bar and grows out of
  // the desktop frame, with concave joins where it meets the frame and the
  // screen edge. `frameStyle: false` gives a plain bordered card sitting below
  // the bar with every corner rounded — same position, no curves.
  property bool frameStyle: true
  // "left" | "right" | "none". Pins the card to a screen edge instead of
  // centering it under its own bar icon.
  property string pinEdge: "none"
  // "top" | "bottom" | "none". "bottom" drops the card onto the screen's
  // bottom edge and grows it upward; every frame decoration mirrors with it,
  // so the card reads as growing out of the desktop frame's bottom corners
  // instead of out of the bar strip.
  property string pinVerticalEdge: "none"
  readonly property bool pinnedBottom: pinVerticalEdge === "bottom"
  // When false the panel stays open until it is closed explicitly (Esc while
  // focused, the bar icon, IPC). Clicks outside the card go straight to
  // whatever is underneath, so the input region shrinks to the card itself and
  // the dismissal surfaces on other outputs are never created.
  property bool dismissOnOutsideClick: true
  property int gap: frameStyle ? -1 : Style.gapsOut  // -1 overlaps the bar so the panel grows from the frame
  property int frameInset: 10  // matches Hyprland gaps_out
  // Distance from the screen edge a pinned card sits at. The frame look lines
  // up with the desktop frame; the plain look uses the ordinary popup margin.
  readonly property int edgeInset: frameStyle ? frameInset : margin
  // A bottom-pinned frame card sits flush against the screen edge, the way a
  // bar-attached one sits flush against the bar strip.
  readonly property int bottomEdgeInset: frameStyle ? 0 : margin
  // The frame look is drawn against the top strip and the desktop frame's
  // corner nooks, both of which assume a top bar. Any other bar position falls
  // back to the plain bordered card.
  readonly property bool framed: frameStyle && barPos === "top"
  readonly property bool attachedRight: framed
     && Math.abs(cardOrigin.x + contentWidth - (screenW - frameInset)) < 2
  readonly property bool attachedLeft: framed
     && Math.abs(cardOrigin.x - frameInset) < 2
  readonly property bool reduceMotion: Quickshell.env("DESKTOP_FRAME_REDUCED_MOTION") === "1"
  // Keep reveal imperative: mapping and animating in the same turn lets
  // Wayland miss the first (and fastest) OutExpo frames on a fresh open.
  property real reveal: 0

  Behavior on reveal {
    NumberAnimation {
      duration: root.reduceMotion ? 0 : (root.open ? 280 : 180)
      easing.type: root.open ? Easing.OutCubic : Easing.OutExpo
    }
  }
  property bool popoutSwitching: false
  property bool popoutSwitchClosing: false
  property bool focusPrimed: false

  // Item that should take keyboard focus once the panel maps. Typically a
  // PanelKeyCatcher inside the panel content. Layer-shell grants focus to the
  // surface during the Exclusive prime, but Qt still needs an active-focus
  // target inside the surface for Keys.onPressed handlers to fire. Schedule
  // the focus through Qt.callLater so it runs after the surface is fully
  // mapped and child items have completed layout.
  property Item focusTarget: null

  default property alias contentItem: contentHolder.children

  readonly property var coordinatorKey: owner || root
  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property string barPos: bar ? bar.position : "top"

  function close() {
    if (owner && "close" in owner) owner.close()
    else root.open = false
  }

  function beginFocusPrime() {
    if (open && backingWindowVisible) focusPrimeTimer.restart()
  }

  // Fresh surfaces mount at reveal=0, then wait one frame before growing
  // down from the bar. Reopening a still-mapped closing surface reverses
  // immediately from its current height instead of flashing closed first.
  function beginReveal() {
    if (!open) return
    if (reduceMotion || reveal > 0) {
      reveal = 1
    } else if (backingWindowVisible) {
      openRevealTimer.restart()
    }
  }

  // --- screen + lifetime ---------------------------------------------------

  screen: anchorWindow ? anchorWindow.screen : null
  visible: open || reveal > 0 || popoutSwitching
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore

  WlrLayershell.namespace: "omarchy-keyboard-panel"
  WlrLayershell.layer: WlrLayer.Overlay
  // Keyboard focus follows `open` (NOT `visible`). The window remains
  // mapped during the fade-out so the opacity animation has something to
  // animate, but keyboard/click ownership must release the moment the
  // logical close fires — otherwise the user is locked out for 140ms.
  //
  // Prime with Exclusive on every open, then settle on OnDemand. Hyprland
  // focuses OnDemand when a surface first maps, but not when an already-mapped
  // fade-out surface changes from None back to OnDemand. Exclusive also takes
  // focus when the previously focused application has constrained the pointer.
  // The brief prime covers both cases; OnDemand then releases compositor-wide
  // pointer hit-testing so clicks can reach the dismissal windows below.
  WlrLayershell.keyboardFocus: open
    ? (focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
    : WlrKeyboardFocus.None

  onBackingWindowVisibleChanged: {
    beginFocusPrime()
    if (backingWindowVisible) beginReveal()
  }

  // Full-screen layer-shell. The visible card is positioned inside via
  // `cardOrigin`. The `mask` below makes the bar area click-through (so
  // the user can click another bar icon while the panel is open and the
  // activePopout coordinator swaps to that popup); everywhere else, the
  // overlay catches the click and dismisses via the MouseArea below.
  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  // Clickable region is the whole screen. Clicks in the bar strip are
  // forwarded to registered bar buttons so switching between panel icons
  // works in one click even when the overlay surface is above the bar.
  readonly property real _barStripSize: {
    if (!bar) return 0
    var actual = (root.barPos === "top" || root.barPos === "bottom") ? root.barH : root.barW
    return Math.max(bar.barSize, actual) + root.gap
  }

  // A persistent panel only claims the card (plus the frame joins beside it),
  // so every click outside it reaches the window below and can focus it. The
  // band follows `reveal` so the region matches what is actually drawn while
  // the card grows and shrinks.
  readonly property int _cardMaskX: attachedLeft ? 0 : Math.max(0, Math.round(cardOrigin.x - Style.cornerRadius))
  readonly property int _cardMaskWidth: {
    var right = attachedRight ? screenW : Math.min(screenW, Math.round(cardOrigin.x + contentWidth + Style.cornerRadius))
    return Math.max(0, right - _cardMaskX)
  }
  mask: Region {
    width: root.dismissOnOutsideClick ? root.screenW : 0
    height: root.dismissOnOutsideClick ? root.screenH : 0

    Region {
      x: root.dismissOnOutsideClick ? 0 : root._cardMaskX
      y: root.dismissOnOutsideClick ? 0 : Math.round(revealClip.y)
      width: root.dismissOnOutsideClick ? 0 : root._cardMaskWidth
      height: root.dismissOnOutsideClick ? 0 : Math.round(revealClip.height)
    }
  }

  // Track every layout change between the bar's contentItem and the
  // anchor item. `transform` updates whenever any item in that chain
  // moves/resizes, which is what makes the position binding below
  // actually reactive — mapToItem on its own is a one-shot.
  TransformWatcher {
    id: anchorWatcher
    a: anchorWindow ? anchorWindow.contentItem : null
    b: anchorItem
  }

  // Anchor item's position within the bar's content surface. For a
  // full-width top bar, the content x maps directly to screen x; the y
  // returned here has the bar's internal padding baked in (e.g. ~13px
  // from vertical centering of the widget row), which is why `cardOrigin`
  // below uses `barH` for the perpendicular axis instead of this y.
  readonly property point anchorScreenPos: {
    anchorWatcher.transform  // reactive dependency
    if (!anchorItem || !anchorWindow) return Qt.point(0, 0)
    return anchorItem.mapToItem(anchorWindow.contentItem, 0, 0)
  }
  readonly property real anchorW: anchorItem ? anchorItem.width : 0
  readonly property real anchorH: anchorItem ? anchorItem.height : 0
  readonly property real screenW: screen ? screen.width : 0
  readonly property real screenH: screen ? screen.height : 0
  readonly property real availableCardWidth: screenW > 0
    ? Math.max(120, screenW - ((barPos === "left" || barPos === "right") ? barW + gap + margin : margin * 2))
    : 0
  readonly property real availableCardHeight: screenH > 0
    ? Math.max(120, pinnedBottom
      ? screenH - barH - gap - (frameStyle ? frameInset : margin)
      : screenH - ((barPos === "top" || barPos === "bottom")
        ? barH + gap + ((frameStyle && barPos === "top") ? frameInset + Style.cornerRadius : margin)
        : margin * 2))
    : 0
  readonly property real verticalContentInset: padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)

  function fittedContentWidth(width, cap) {
    var desired = Math.max(1, Number(width) || 1)
    var maxWidth = root.availableCardWidth > 0 ? root.availableCardWidth : desired
    if (cap !== undefined && Number(cap) > 0) maxWidth = Math.min(maxWidth, Number(cap))
    return Math.round(Math.min(desired, maxWidth))
  }

  function fittedContentHeight(implicitHeight, cap) {
    var desired = Math.max(root.verticalContentInset, (Number(implicitHeight) || 0) + root.verticalContentInset)
    var maxHeight = root.availableCardHeight > 0 ? root.availableCardHeight : desired
    if (cap !== undefined && Number(cap) > 0) maxHeight = Math.min(maxHeight, Number(cap))
    return Math.round(Math.min(desired, maxHeight))
  }

  function cappedContentHeight(height) {
    var desired = Math.max(root.padding * 2, Number(height) || root.padding * 2)
    var maxHeight = root.availableCardHeight > 0 ? root.availableCardHeight : desired
    return Math.round(Math.min(desired, maxHeight))
  }

  // Desired top-left of the card in screen coordinates. For the
  // perpendicular axis (away-from-bar) we anchor to the bar window's edge
  // directly — not the anchor item's y/x — because mapToItem(barContent)
  // returns coordinates in the bar's content space, which can be offset
  // from the bar surface's screen-anchored corner by internal layout
  // (centering wrappers, padding). The bar's surface IS aligned to its
  // anchored screen edge, so using `barW`/`barH` gives the right edge
  // regardless of how the bar's internal widgets are positioned. For the
  // parallel axis (along the bar) the anchor item's reported position is
  // still consistent with the bar content origin, so it's accurate for
  // centering the card under the icon.
  readonly property real barW: anchorWindow ? anchorWindow.width : screenW
  readonly property real barH: anchorWindow ? anchorWindow.height : 0
  readonly property point cardOrigin: {
    if (!anchorItem || !bar) return Qt.point(margin, margin)
    var x = 0, y = 0
    if (centerOnBar && (barPos === "top" || barPos === "bottom")) {
      x = screenW / 2 - contentWidth / 2
      y = barPos === "bottom" ? screenH - barH - contentHeight - gap : barH + gap
    } else if (centerOnBar) {
      x = barPos === "left" ? barW + gap : screenW - barW - contentWidth - gap
      y = screenH / 2 - contentHeight / 2
    } else if (barPos === "bottom") {
      x = anchorScreenPos.x + anchorW / 2 - contentWidth / 2
      y = screenH - barH - contentHeight - gap
    } else if (barPos === "left") {
      x = barW + gap
      y = anchorScreenPos.y + anchorH / 2 - contentHeight / 2
    } else if (barPos === "right") {
      x = screenW - barW - contentWidth - gap
      y = anchorScreenPos.y + anchorH / 2 - contentHeight / 2
    } else { // "top" (default)
      x = anchorScreenPos.x + anchorW / 2 - contentWidth / 2
      y = barH + gap
    }
    // A pinned card ignores its icon's position along the bar. The clamp below
    // would land on the same number for `left`, but only while gapsOut and
    // frameInset agree — pin explicitly so the frame joins keep lining up when
    // they don't.
    if (pinEdge === "left") x = edgeInset
    else if (pinEdge === "right") x = screenW - contentWidth - edgeInset
    // Same idea on the other axis: a bottom-pinned card ignores the bar it
    // hangs from and lands on the screen's bottom edge.
    if (pinnedBottom) y = screenH - contentHeight - bottomEdgeInset

    var leftMargin = pinEdge === "left" ? edgeInset : margin
    var rightMargin = (frameStyle && barPos === "top") ? frameInset : margin
    var bottomMargin = pinnedBottom ? bottomEdgeInset : margin
    x = Math.max(leftMargin, Math.min(x, screenW - contentWidth - rightMargin))
    y = Math.max(margin, Math.min(y, screenH - contentHeight - bottomMargin))
    return Qt.point(Math.round(x), Math.round(y))
  }


  // --- popout coordination (same-bar single-popout model) -----------------

  // Coordinate on `open`, not `visible`. `visible` lags into the fade-out
  // animation, which made ownership transfer to a sibling popup race.
  onOpenChanged: {
    if (open) {
      focusPrimed = false
      beginFocusPrime()
      beginReveal()
      if (focusTarget) Qt.callLater(function() {
        if (root.open && root.focusTarget) root.focusTarget.forceActiveFocus()
      })
    } else {
      openRevealTimer.stop()
      reveal = 0
      focusPrimeTimer.stop()
      focusPrimed = false
    }
    if (!bar) return
    if (open) {
      popoutSwitchClosing = false
      popoutSwitching = bar.activePopout && bar.activePopout !== coordinatorKey
      bar.requestPopout(coordinatorKey)
      if (popoutSwitching) popoutSwitchTimer.restart()
    } else {
      popoutSwitchClosing = !!(owner && owner.popoutSwitchClosing)
      popoutSwitching = false
      if (bar.activePopout === coordinatorKey) bar.releasePopout(coordinatorKey)
      if (popoutSwitchClosing) closeSwitchTimer.restart()
    }
  }

  Timer {
    id: openRevealTimer
    interval: 16
    onTriggered: if (root.open) root.reveal = 1
  }

  Timer {
    id: focusPrimeTimer
    // Leave enough time for multiple Qt/Wayland commit cycles after the
    // backing window becomes visible while keeping the compositor-wide
    // Exclusive phase imperceptibly short. This interval is covered by the
    // immediate hide/re-summon acceptance case.
    interval: 75
    onTriggered: if (root.open) root.focusPrimed = true
  }

  Timer {
    id: popoutSwitchTimer
    interval: 150
    onTriggered: root.popoutSwitching = false
  }

  Timer {
    id: closeSwitchTimer
    interval: 1
    onTriggered: root.popoutSwitchClosing = false
  }

  // --- outside-click dismissal --------------------------------------------

  // Catches clicks anywhere in the clickable region (i.e. everywhere on
  // screen except the bar strip, which is masked out). The card has its
  // own MouseArea below so clicks on it don't bubble up here. Disabled
  // during the fade-out so the dying overlay doesn't swallow clicks that
  // were meant for the apps behind it, and disabled outright for a
  // persistent panel, whose input region excludes everything but the card.
  MouseArea {
    id: dismissArea
    anchors.fill: parent
    enabled: root.open && root.dismissOnOutsideClick
    acceptedButtons: Qt.AllButtons
    hoverEnabled: root.dismissOnOutsideClick
    property bool hoveringBar: false
    cursorShape: hoveringBar ? Qt.PointingHandCursor : Qt.ArrowCursor

    function inBarRegion(px, py) {
      if (root.barPos === "bottom") return py >= root.screenH - root._barStripSize
      if (root.barPos === "left") return px <= root._barStripSize
      if (root.barPos === "right") return px >= root.screenW - root._barStripSize
      return py <= root._barStripSize
    }

    function barPoint(px, py) {
      if (root.barPos === "bottom") return Qt.point(px, py - (root.screenH - root.barH))
      if (root.barPos === "right") return Qt.point(px - (root.screenW - root.barW), py)
      return Qt.point(px, py)
    }

    function pressTargetAt(px, py) {
      if (!root.anchorWindow || !root.anchorWindow.contentItem || !root.bar || !root.bar.clickTargets) return null
      var p = barPoint(px, py)
      var targets = root.bar.clickTargets
      for (var i = targets.length - 1; i >= 0; i--) {
        var target = targets[i]
        if (!target || !target.triggerPress || target.visible === false || target.opacity === 0 || !target.mapToItem) continue
        if (root.bar.targetBelongsToWindow && !root.bar.targetBelongsToWindow(target, root.anchorWindow)) continue
        var pos = root.anchorWindow.itemPosition(target)
        if (p.x >= pos.x && p.x <= pos.x + target.width && p.y >= pos.y && p.y <= pos.y + target.height) return target
      }
      return null
    }

    function forwardBarClick(px, py, button) {
      if (button !== Qt.LeftButton && button !== Qt.RightButton && button !== Qt.MiddleButton) return false
      var target = pressTargetAt(px, py)
      if (!target) return false
      target.triggerPress(button)
      return true
    }

    onPositionChanged: function(mouse) { hoveringBar = inBarRegion(mouse.x, mouse.y) }
    onExited: hoveringBar = false
    onClicked: function(mouse) {
      // While Exclusive is priming, Hyprland may route a click from another
      // output here with translated coordinates. Never interpret that as a
      // click on this output's bar.
      if (root.focusPrimed && inBarRegion(mouse.x, mouse.y) && forwardBarClick(mouse.x, mouse.y, mouse.button)) return
      root.close()
    }
  }

  // The panel surface only spans the anchor's screen, and the compositor
  // hit-tests pointer input per output, so `dismissArea` above can never see
  // a click on another monitor. Give every other output a transparent twin
  // whose only job is to catch that click. They exist only while the panel is
  // logically open (not during the fade-out, matching `dismissArea.enabled`).
  //
  // Keyboard focus is None: these must catch the pointer without taking focus
  // from the panel when the cursor merely crosses onto their output.
  Variants {
    model: root.open && root.dismissOnOutsideClick ? Quickshell.screens : []

    delegate: Component {
      PanelWindow {
        required property var modelData

        screen: modelData
        // Compare by output name: the anchor screen must be known before any
        // twin maps, or a twin would cover the panel's own output.
        visible: root.open && !!root.screen && modelData.name !== root.screen.name
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.namespace: "omarchy-keyboard-panel-dismiss"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
          top: true
          bottom: true
          left: true
          right: true
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onPressed: root.close()
        }
      }
    }
  }

  // --- card ----------------------------------------------------------------

  // Grows from the edge the card is attached to: down from the bar strip, or
  // up from the screen's bottom edge. The extra corner-radius band is where the
  // concave joins at the card's free end are drawn.
  Item {
    id: revealClip
    x: 0
    y: root.pinnedBottom
      ? Math.round(root.cardOrigin.y + root.contentHeight - height)
      : Math.round(root.cardOrigin.y)
    width: root.screenW
    height: Math.round((root.contentHeight + Style.cornerRadius) * root.reveal)
    clip: true
  }

  // Frame joins live in `revealClip` coordinates. `attachedEdgeJoinY` is the
  // edge the card grows out of; `freeEdgeJoinY` is where a side bridge to the
  // screen edge stops and curves away.
  readonly property int frameJoinSize: Style.cornerRadius
  readonly property int attachedEdgeJoinY: pinnedBottom
    ? Math.round(card.y + card.height - frameJoinSize) : Math.round(card.y)
  readonly property int freeEdgeJoinY: pinnedBottom
    ? Math.round(card.y - frameJoinSize + 2) : Math.round(card.y + card.height - 2)

  FrameJoin {
    id: leftFrameJoin
    parent: revealClip
    visible: root.framed && !root.attachedLeft
    x: card.x - width + 2
    y: root.attachedEdgeJoinY
    opacity: card.opacity
    cornerRadius: root.frameJoinSize
    frameColor: Color.popups.background
    transform: Scale {
      origin.x: leftFrameJoin.width / 2
      origin.y: leftFrameJoin.height / 2
      yScale: root.pinnedBottom ? -1 : 1
    }
  }

  FrameJoin {
    id: rightFrameJoin
    parent: revealClip
    visible: root.framed && !root.attachedRight
    x: card.x + card.width - 2
    y: root.attachedEdgeJoinY
    opacity: card.opacity
    cornerRadius: root.frameJoinSize
    frameColor: Color.popups.background
    transform: Scale {
      origin.x: rightFrameJoin.width / 2
      origin.y: rightFrameJoin.height / 2
      xScale: -1
      yScale: root.pinnedBottom ? -1 : 1
    }
  }

  // A panel pinned to the right runs into the screen edge instead: the strip
  // bridges the gaps_out inset, and the fillet below curves into the edge.
  Rectangle {
    parent: revealClip
    visible: root.attachedRight
    x: card.x + card.width - 2
    y: card.y
    width: root.frameInset + 2
    height: card.height
    color: Color.popups.background
    opacity: card.opacity
  }

  FrameJoin {
    id: rightBridgeFrameJoin
    parent: revealClip
    visible: root.attachedRight
    x: root.screenW - width
    y: root.freeEdgeJoinY
    opacity: card.opacity
    cornerRadius: root.frameJoinSize
    frameColor: Color.popups.background
    transform: Scale {
      origin.x: rightBridgeFrameJoin.width / 2
      origin.y: rightBridgeFrameJoin.height / 2
      yScale: root.pinnedBottom ? -1 : 1
    }
  }

  // Mirror of the two items above for a panel pinned to the left edge.
  Rectangle {
    parent: revealClip
    visible: root.attachedLeft
    x: 0
    y: card.y
    width: card.x + 2
    height: card.height
    color: Color.popups.background
    opacity: card.opacity
  }

  FrameJoin {
    id: leftBridgeFrameJoin
    parent: revealClip
    visible: root.attachedLeft
    x: 0
    y: root.freeEdgeJoinY
    opacity: card.opacity
    cornerRadius: root.frameJoinSize
    frameColor: Color.popups.background
    transform: Scale {
      origin.x: leftBridgeFrameJoin.width / 2
      origin.y: leftBridgeFrameJoin.height / 2
      xScale: -1
      yScale: root.pinnedBottom ? -1 : 1
    }
  }

  BorderSurface {
    parent: revealClip
    id: card
    x: root.cardOrigin.x
    y: root.pinnedBottom ? revealClip.height - root.contentHeight : 0
    width: root.contentWidth
    height: root.contentHeight
    color: Color.popups.background
    // The frame look draws its own edges, so the card drops its border and
    // squares off every corner that meets the bar strip, a bridged screen edge,
    // or the bottom of the screen. The free corners keep the popup radius.
    borderSpec: root.framed ? Border.none() : root.borderSpec
    padding: root.padding
    radius: Style.cornerRadius
    topLeftRadius: root.framed && (root.pinnedBottom ? root.attachedLeft : true) ? 0 : Style.cornerRadius
    topRightRadius: root.framed && (root.pinnedBottom ? root.attachedRight : true) ? 0 : Style.cornerRadius
    bottomRightRadius: root.framed && (root.pinnedBottom || root.attachedRight) ? 0 : Style.cornerRadius
    bottomLeftRadius: root.framed && (root.pinnedBottom || root.attachedLeft) ? 0 : Style.cornerRadius
    opacity: 1

    // Swallow clicks on the card so they don't bubble to the dismissal
    // MouseArea behind us. Pressing the card also restores Qt active focus to
    // `focusTarget`: the compositor hands keyboard focus back to this surface
    // on the click, but a persistent panel can have lost it to another window
    // long ago, and Esc has to land on the panel again right away. Content
    // items sit above this area, so a press on a field still goes to the field.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
      onPressed: if (root.open && root.focusTarget) root.focusTarget.forceActiveFocus()
    }

    Item {
      id: contentHolder
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
      // Panel itself grows from the bar; content follows by a few pixels and
      // fades in, preventing the first clipped text row from popping onscreen.
      opacity: (root.reduceMotion ? 1 : Math.min(1, root.reveal * 1.7))
        * (root.popoutSwitching ? (root.open ? 1.0 : 0) : 1.0)
      transform: Translate {
        // Content trails the card, sliding in from the edge it grows out of.
        y: root.reduceMotion ? 0
          : (root.pinnedBottom ? 1 : -1) * (1 - root.reveal) * Style.space(8)
      }

      Behavior on opacity {
        enabled: root.popoutSwitching
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }
    }
  }
}
