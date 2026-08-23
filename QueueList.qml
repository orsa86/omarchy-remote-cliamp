import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The queue, 1a-style: a leader-line header with the count, quiet rows, the
// playing row in accent with a ▶, and a one-line key hint under the list.
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool expanded: false
  property int cursorIndex: -1

  signal toggleRequested()

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property var tracks: service ? service.queue : []
  readonly property int playingIndex: service ? service.queueIndex : -1

  // An album queue repeats one artist forty times and the repeated prefix
  // elides every title. When the whole queue is one artist the rows drop the
  // name (the hero already shows it) and give the width to the titles.
  readonly property bool oneArtist: {
    if (tracks.length < 2) return false
    var first = String(tracks[0].artist || "")
    if (first.length === 0) return false
    for (var i = 1; i < tracks.length; i++) {
      if (String(tracks[i].artist || "") !== first) return false
    }
    return true
  }

  readonly property Item listItem: queueList

  readonly property int listMaxHeight: Style.space(240)

  onCursorIndexChanged: if (cursorIndex >= 0) queueList.positionViewAtIndex(cursorIndex, ListView.Contain)

  spacing: Style.space(6)

  SectionHead {
    width: parent.width
    text: "QUEUE"
    count: root.tracks.length > 0 ? String(root.tracks.length) : ""

    chevron: !root.expanded
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: root.toggleRequested()
  }

  // Collapsed: the playing row alone stands in for the whole list.
  RowSurface {
    width: parent.width
    visible: !root.expanded
    foreground: root.foreground

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleRequested()
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: {
          if (root.tracks.length === 0) return "queue is empty"
          var at = root.playingIndex
          var now = at >= 0 && at < root.tracks.length ? root.tracks[at] : null
          return now
            ? "#" + (at + 1) + "  " + (now.artist ? now.artist + " · " : "") + now.title
            : root.tracks.length + " queued"
        }
        color: root.tracks.length === 0 ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
    }
  }

  ListView {
    id: queueList
    width: parent.width
    height: Math.min(contentHeight, root.listMaxHeight)
    visible: root.expanded
    clip: true
    model: root.tracks
    keyNavigationEnabled: false
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded; interactive: false }

    onCountChanged: if (root.cursorIndex >= 0) positionViewAtIndex(root.cursorIndex, ListView.Contain)

    delegate: RowSurface {
      id: qrow
      required property var modelData
      required property int index

      width: queueList.width
      foreground: root.foreground
      hasCursor: index === root.cursorIndex
      playing: index === root.playingIndex

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: function (mouse) {
          if (!root.service) return
          if (mouse.button === Qt.RightButton) root.service.queueRemove(index)
          else root.service.queueJump(index)
        }
      }

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          text: qrow.playing ? "▶" : String(index + 1)
          color: qrow.playing ? Color.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignRight
          Layout.preferredWidth: Style.space(20)
        }

        // The cursor row scrolls its full text (MarqueeText only moves when it
        // overflows); rows at rest stay clipped and quiet.
        MarqueeText {
          Layout.fillWidth: true
          text: (!root.oneArtist && modelData.artist ? modelData.artist + " · " : "") + modelData.title
          color: qrow.playing ? Color.accent : root.foreground
          fontFamily: root.fontFamily
          pixelSize: Style.font.body
          active: qrow.hasCursor
        }

        Text {
          textFormat: Text.PlainText
          text: modelData.isStream ? "live" : Model.formatTime(modelData.durationSec)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: root.expanded && root.tracks.length > 0
    text: "enter jump · x remove · [ ] move"
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    leftPadding: Style.space(10)
  }
}
