import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "omacava"

  readonly property int configuredBars: setting("bars", 24)
  readonly property bool autoHideSetting: setting("autoHide", false)

  // Portable directory resolution for standalone packaging
  readonly property string pluginDir: {
    var u = Qt.resolvedUrl(".").toString()
    if (u.indexOf("file://") === 0) return u.substring(7)
    return u
  }
  readonly property string cavaConfPath: pluginDir + "/cava.conf"

  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var mediaService: root.bar && root.bar.shell ? root.bar.shell.firstPartyServiceFor("omarchy.media") : null

  // Universal System-Wide Media Selection: works for ANY MPRIS player
  // (Spotify, VLC, browser tabs, YouTube Music, ...), not just YT Music.
  readonly property var activePlayer: {
    if (mediaService && mediaService.activePlayer) return mediaService.activePlayer

    if (!players || players.length === 0) return null

    // 1. Any player actively playing with track info
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (p && p.isPlaying && (p.trackTitle || p.trackArtist)) {
        return p
      }
    }

    // 2. Any player actively playing even without full metadata
    for (var i2 = 0; i2 < players.length; i2++) {
      if (players[i2] && players[i2].isPlaying) return players[i2]
    }

    // 3. Any other player with metadata
    for (var k = 0; k < players.length; k++) {
      var p3 = players[k]
      if (p3 && (p3.trackTitle || p3.trackArtist)) {
        return p3
      }
    }

    return players[0]
  }

  readonly property bool hasValidTrack: activePlayer !== null && !!activePlayer.trackTitle && activePlayer.trackTitle !== "Nothing Playing"
  readonly property bool hasMedia: hasValidTrack
  readonly property bool isPlaying: activePlayer ? !!activePlayer.isPlaying : false

  // omamusic-style naming, applied to any player
  readonly property string title: activePlayer ? (activePlayer.trackTitle || "Untitled track") : ""
  readonly property string artist: activePlayer ? (activePlayer.trackArtist || "") : ""
  readonly property string tooltipMsg: activePlayer
    ? (root.title + (root.artist ? " — " + root.artist : ""))
    : "No media playing"

  // Click routing: the bar's modulePointer dispatches presses to triggerPress
  readonly property bool pressable: true
  function triggerPress(button) {
    if (button === Qt.LeftButton || button === undefined || button === 1) {
      root.triggerPlayPause()
    }
    // Right click intentionally does nothing
  }

  property var registeredBar: null
  function syncClickRegistration() {
    if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)
    registeredBar = root.bar
    if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(root)
  }
  onBarChanged: syncClickRegistration()
  Component.onDestruction: if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)

  // Volume Controller with Live Omarchy OSD Feedback
  function outputVolumeIcon(volume) {
    if (volume >= 0.67) return ""
    if (volume >= 0.34) return ""
    if (volume > 0) return ""
    return ""
  }

  function adjustVolume(delta) {
    var sink = Pipewire.defaultAudioSink
    if (sink && sink.audio) {
      var cur = sink.audio.volume
      var target = Math.max(0.0, Math.min(1.0, cur + delta))
      sink.audio.volume = target
      if (root.bar && root.bar.shell) {
        root.bar.shell.summon("omarchy.osd", JSON.stringify({
          icon: outputVolumeIcon(target),
          value: Math.round(target * 100)
        }))
      }
    } else if (root.activePlayer && root.activePlayer.volume !== undefined) {
      root.activePlayer.volume = Math.max(0.0, Math.min(1.0, root.activePlayer.volume + delta))
    }
  }

  // Click pauses whatever is playing (any media). No player -> no-op.
  function triggerPlayPause() {
    if (activePlayer && typeof activePlayer.togglePlaying === "function") {
      activePlayer.togglePlaying()
    } else if (isPlaying && typeof activePlayer.pause === "function") {
      activePlayer.pause()
    } else if (activePlayer && typeof activePlayer.play === "function") {
      activePlayer.play()
    }
  }

  // CAVA Real-Time Audio Equalizer Data
  property var levels: []
  property bool hasAudio: false
  property int silentFrames: 0

  function initLevels() {
    var arr = []
    for (var i = 0; i < root.configuredBars; i++) arr.push(0.0)
    root.levels = arr
  }

  function updateBars(line) {
    if (!line) return
    var parts = String(line).trim().split(";")
    var newLevels = []
    var sum = 0

    for (var i = 0; i < root.configuredBars; i++) {
      var val = i < parts.length ? (parseFloat(parts[i]) || 0) : 0
      var norm = Math.min(1.0, Math.max(0.0, val / 100.0))
      newLevels.push(norm)
      sum += norm
    }

    root.levels = newLevels
    if (sum > 0.005) {
      root.hasAudio = true
      root.silentFrames = 0
    } else {
      root.silentFrames += 1
      if (root.silentFrames > 20) root.hasAudio = false
    }
  }

  Component.onCompleted: initLevels()
  onConfiguredBarsChanged: initLevels()

  Process {
    id: cavaProc
    command: ["cava", "-p", root.cavaConfPath]
    running: true

    stdout: SplitParser {
      onRead: function(line) {
        root.updateBars(line)
      }
    }

    onExited: function(exitCode) {
      restartTimer.start()
    }
  }

  Timer {
    id: restartTimer
    interval: 1500
    repeat: false
    onTriggered: {
      if (!cavaProc.running) cavaProc.running = true
    }
  }

  visible: !autoHideSetting || hasAudio || hasMedia
  implicitWidth: eqRow.implicitWidth + Style.space(8)
  implicitHeight: barSize

  // 24-Bar High-Density CAVA Equalizer Visualizer in the status bar
  Row {
    id: eqRow
    anchors.centerIn: parent
    spacing: Style.spaceReal(1.8)
    height: Math.max(16, root.barSize - Style.space(4))

    Repeater {
      model: root.configuredBars

      Rectangle {
        id: barItem
        required property int index

        readonly property real level: (index < root.levels.length) ? root.levels[index] : 0.0
        readonly property real maxBarHeight: eqRow.height
        readonly property real minBarHeight: Style.spaceReal(2.0)

        width: Style.spaceReal(2.5)
        height: Math.max(minBarHeight, Math.round(level * maxBarHeight))
        anchors.verticalCenter: parent.verticalCenter
        radius: width / 2.0

        color: root.hasAudio
          ? (level > 0.75 ? Qt.lighter(Color.accent, 1.25) : Color.accent)
          : Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 2.0)

        opacity: root.hasAudio ? Math.max(0.65, 0.45 + level * 0.55) : 0.35

        Behavior on height {
          NumberAnimation {
            duration: 35
            easing.type: Easing.OutCubic
          }
        }

        Behavior on color {
          ColorAnimation { duration: 100 }
        }
      }
    }
  }

  // Wheel + hover surface. Clicks are routed by the bar to triggerPress, so
  // this area takes no buttons — it only watches the wheel and hover.
  MouseArea {
    id: wheelArea
    anchors.fill: parent
    z: 10
    acceptedButtons: Qt.NoButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    onWheel: function(wheel) {
      root.adjustVolume(wheel.angleDelta.y > 0 ? 0.04 : -0.04)
    }

    onEntered: root.tipVisible = true
    onExited: root.tipVisible = false
  }

  property bool tipVisible: false

  // Self-contained tooltip: anchored to this widget's own window, fully
  // independent of the bar's built-in tooltip plumbing.
  PopupWindow {
    id: tipWindow
    visible: root.tipVisible && root.QsWindow !== null

    color: "transparent"
    implicitWidth: Math.ceil(tipBubble.implicitWidth)
    implicitHeight: Math.ceil(tipBubble.implicitHeight)

    anchor {
      id: tipAnchor
      window: root.QsWindow ? root.QsWindow.window : null
      adjustment: PopupAdjustment.Slide
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
      rect.width: 1
      rect.height: 1

      onAnchoring: {
        var win = root.QsWindow ? root.QsWindow.window : null
        if (!win) return

        var localX = root.width / 2 - tipWindow.implicitWidth / 2
        var localY = root.height + 6
        if (root.bar && root.bar.position === "bottom") {
          localY = -tipWindow.implicitHeight - 6
        }

        var point = win.contentItem.mapFromItem(root, localX, localY)
        tipAnchor.rect.x = Math.round(point.x)
        tipAnchor.rect.y = Math.round(point.y)
      }
    }

    BorderSurface {
      id: tipBubble
      implicitWidth: tipLabel.implicitWidth + 20
      implicitHeight: tipLabel.implicitHeight + 14
      color: Color.tooltip.background
      borderSpec: Border.surfaceSpec("tooltip", "border", Color.tooltip.border, 1)
      radius: Style.cornerRadius

      Text {
        id: tipLabel
        anchors.centerIn: parent
        text: root.tooltipMsg
        color: Color.tooltip.text
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }
  }
}