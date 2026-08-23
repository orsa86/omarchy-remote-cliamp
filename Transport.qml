import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

Column {
  id: root

  property QtObject bar: null
  property var service: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal queueRequested()

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property bool live: !!(service && service.running)
  readonly property bool shuffling: !!(service && service.shuffle)
  readonly property bool repeating: !!(service && service.repeat !== "Off")

  spacing: Style.space(8)

  // Bare glyphs on air, no discs: the play mark alone carries the accent.
  Row {
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Style.space(22)

    TransportButton {
      glyph: "⇄"
      size: Style.font.heading
      enabled: root.live
      color: root.shuffling ? root.foreground : root.dim
      anchors.verticalCenter: parent.verticalCenter
      onActivated: root.service.toggleShuffle()
    }

    TransportButton {
      shape: "prev"
      size: Style.font.heading
      enabled: root.live
      color: root.dim
      anchors.verticalCenter: parent.verticalCenter
      onActivated: root.service.previous()
    }

    TransportButton {
      shape: root.service && root.service.showPlaying ? "pause" : "play"
      size: Style.font.heading + Style.space(6)
      enabled: root.live
      color: Color.accent
      anchors.verticalCenter: parent.verticalCenter
      onActivated: root.service.playPause()
    }

    TransportButton {
      shape: "next"
      size: Style.font.heading
      enabled: root.live
      color: root.dim
      anchors.verticalCenter: parent.verticalCenter
      onActivated: root.service.next()
    }

    TransportButton {
      glyph: root.service && root.service.repeat === "One" ? "↻¹" : "↻"
      size: Style.font.heading
      enabled: root.live
      color: root.repeating ? root.foreground : root.dim
      anchors.verticalCenter: parent.verticalCenter
      onActivated: root.service.cycleRepeat()
    }
  }

  Text {
    textFormat: Text.PlainText
    anchors.horizontalCenter: parent.horizontalCenter
    text: root.service && root.service.total > 0 ? root.service.total + " in queue" : ""
    color: queueTap.containsMouse ? root.foreground : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    visible: text.length > 0

    MouseArea {
      id: queueTap
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.queueRequested()
    }
  }

  // cliamp's own gain over the socket, dB in [-30, +6]. A 2px line and a
  // square knob — plain foreground; the accent stays with playback.
  Column {
    width: parent.width
    spacing: Style.space(2)
    visible: root.live

    // Local server: the slider is cliamp's PipeWire stream volume (float,
    // ramped, cannot clip; 100% = the samples untouched). Remote servers keep
    // cliamp's socket gain in dB — their graph is elsewhere.
    readonly property bool streamVol: !!(root.service && root.service.hasStreamVolume)

    SectionHead {
      width: parent.width
      text: "VOLUME"
      count: {
        if (!root.service) return ""
        if (parent.streamVol) return Math.round(root.service.streamVolume * 100) + " %"
        var db = Math.round(root.service.shownVolumeDb)
        return (db > 0 ? "+" + db : String(db)) + " dB"
      }
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    LineSlider {
      width: parent.width - Style.space(12)
      anchors.horizontalCenter: parent.horizontalCenter
      minimum: parent.streamVol ? 0 : -30
      maximum: parent.streamVol ? 100 : 6
      value: {
        if (!root.service) return 0
        return parent.streamVol ? root.service.streamVolume * 100 : root.service.shownVolumeDb
      }
      // Socket gain above 0 dB clips the samples before the DAC — a stray
      // click on the slider's right end lands there silently, so the line
      // turns urgent while it does. Stream volume tops out at 100%: no danger.
      foreground: !parent.streamVol && root.service && root.service.shownVolumeDb > 0
        ? Color.urgent : root.foreground
      enabled: root.live
      onMoved: function (v) {
        if (!root.service) return
        if (parent.streamVol) root.service.setStreamVolume(v / 100)
        else root.service.setVolumeDb(v)
      }
      onRightClicked: {
        if (!root.service) return
        if (parent.streamVol) root.service.setStreamVolume(1)
        else root.service.setVolumeDb(0)
      }
    }
  }
}
