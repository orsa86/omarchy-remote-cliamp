import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Variant-1a hero. One fixed geometry across track / radio / idle / offline —
// the art box, title, meta line and status line all hold their places, so
// nothing shifts when the state does. Accent appears only where the spec
// allows: the analyzer, the live dot, the playing marks.
Column {
  id: root

  property var service: null
  property string phrase: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color sunken: Qt.darker(foreground, 4.2)
  readonly property int artSize: Style.space(64)
  readonly property bool hasTrack: !!(service && service.hasTrack)
  readonly property bool isStream: !!(service && service.isStream)
  readonly property bool running: !!(service && service.running)
  readonly property bool offline: !!(service && !service.tunnelUp)
  readonly property bool seekable: !!(service && service.canSeek)
  // A Navidrome track arrives as an HTTP stream: its duration is known, so the
  // bar is drawn — but cliamp cannot reposition a stream, so it is not
  // interactive. Radio has no duration at all and shows no bar.
  readonly property bool showProgress: !!(service && service.hasProgress)

  readonly property string metaLine: {
    if (!service) return ""
    var artist = String(service.artist || "")
    var album = String(service.album || "")
    if (artist.length > 0 && album.length > 0) return artist + " · " + album
    if (artist.length > 0 || album.length > 0) return artist.length > 0 ? artist : album
    return ""
  }

  spacing: Style.space(8)

  Row {
    width: parent.width
    height: Math.max(root.artSize + Style.space(12), Style.space(76))
    spacing: Style.space(14)

    // The art box: cover art for a track, a breathing accent meter for radio,
    // the static mark while idle, and a dimmed × when the server is gone.
    Rectangle {
      width: root.artSize
      height: root.artSize
      color: root.sunken
      clip: true
      anchors.top: parent.top
      opacity: root.offline ? 0.6 : 1

      Image {
        id: art
        anchors.fill: parent
        source: root.service ? root.service.artUrl : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        sourceSize.width: root.service ? root.service.artSizePx : 300
        sourceSize.height: root.service ? root.service.artSizePx : 300
        opacity: status === Image.Ready ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 160 } }
      }

      CliampIcon {
        anchors.centerIn: parent
        iconSize: root.artSize * 0.34
        color: root.isStream && root.running ? Color.accent : root.dim
        playing: root.isStream && root.running && root.service.isPlaying
        visible: art.status !== Image.Ready && !root.offline
        opacity: root.running ? 1 : 0.5
      }

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        visible: root.offline
        text: "×"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: root.artSize * 0.4
      }
    }

    Column {
      width: parent.width - root.artSize - Style.space(14)
      spacing: 0
      anchors.top: parent.top
      anchors.topMargin: Style.space(2)

      MarqueeText {
        width: parent.width
        text: root.hasTrack ? root.service.title
          : "cliamp @ " + (root.service ? root.service.label : "?")
        color: root.hasTrack ? root.foreground : root.dim
        fontFamily: root.fontFamily
        pixelSize: Style.font.title
        bold: true
      }

      // Meta keeps its slot in every state, so the hero never jumps: track
      // meta, an accent live dot for radio, or nothing but the reserved space.
      Row {
        width: parent.width
        height: Math.max(Style.space(12), metaText.implicitHeight)
        spacing: Style.space(5)

        Rectangle {
          width: Style.space(5)
          height: Style.space(5)
          radius: width / 2
          color: Color.accent
          visible: root.isStream && root.metaLine.length === 0 && root.running
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: metaText
          textFormat: Text.PlainText
          width: parent.width - (root.isStream && root.metaLine.length === 0 ? Style.space(10) : 0)
          text: (root.hasTrack
            ? (root.metaLine.length > 0 ? root.metaLine
               : root.isStream ? "live · radio" : "")
            : "").toUpperCase()
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
          elide: Text.ElideRight
        }
      }

      // 16 thin bars interpolated over cliamp's 10 bands, solid accent, quick
      // height moves — quieter than LEDs, still unmistakably a spectrum.
      Item {
        id: analyzer
        width: parent.width
        height: Style.space(12)
        visible: root.hasTrack

        readonly property var bands: root.service ? root.service.bands : []
        readonly property int barCount: 16

        function level(i) {
          var b = bands
          if (!b || b.length === 0) return 0
          var pos = i * (b.length - 1) / (barCount - 1)
          var lo = Math.floor(pos)
          var hi = Math.min(b.length - 1, lo + 1)
          var t = pos - lo
          return b[lo] * (1 - t) + b[hi] * t
        }

        Row {
          anchors.left: parent.left
          anchors.bottom: parent.bottom
          height: parent.height
          spacing: 2

          Repeater {
            model: analyzer.barCount

            Rectangle {
              required property int index
              width: 2
              height: Math.max(1, analyzer.height * analyzer.level(index))
              anchors.bottom: parent.bottom
              color: Color.accent
              Behavior on height { NumberAnimation { duration: 70 } }
            }
          }
        }
      }

      // Status line: the lyric being sung, radio's honest "stream · no seek",
      // or the offline report — the only urgent text in the panel. A long
      // lyric elides; the full sheet lives on `y`.
      Text {
        textFormat: Text.PlainText
        width: parent.width
        topPadding: Style.space(6)
        visible: text.length > 0
        text: root.offline
          ? "offline — " + (root.service ? root.service.sshTarget : "")
          : root.hasTrack
            ? (root.service.activeLyric.length > 0 ? root.service.activeLyric
               : root.isStream && !root.showProgress && root.running ? "stream · no seek" : "")
            : root.phrase
        color: root.offline ? Color.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
    }
  }

  Column {
    width: parent.width
    spacing: Style.space(5)
    visible: root.showProgress

    Item {
      width: parent.width
      height: 2

      Rectangle {
        anchors.fill: parent
        color: Qt.alpha(root.foreground, 0.12)
      }

      Rectangle {
        id: progress
        height: parent.height
        color: Color.accent
        width: {
          if (!root.service || root.service.lengthSec <= 0) return 0
          return parent.width * Math.max(0, Math.min(1, root.service.positionSec / root.service.lengthSec))
        }
      }

      MouseArea {
        anchors.fill: parent
        anchors.topMargin: -Style.space(8)
        anchors.bottomMargin: -Style.space(8)
        hoverEnabled: true
        enabled: root.seekable
        cursorShape: Qt.PointingHandCursor
        onClicked: function (mouse) {
          if (!root.service || root.service.lengthSec <= 0) return
          root.service.seekTo(root.service.lengthSec * (mouse.x / width))
        }
      }
    }

    Item {
      width: parent.width
      height: elapsed.implicitHeight

      Text {
        id: elapsed
        textFormat: Text.PlainText
        anchors.left: parent.left
        text: root.service ? Model.formatTime(root.service.positionSec) : "0:00"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        text: root.service ? Model.formatTime(root.service.lengthSec) : "0:00"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
