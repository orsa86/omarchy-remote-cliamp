import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// The full lyric sheet, on the native player's `y`. The active line carries
// the accent and the list follows it karaoke-style; scrolling by hand pauses
// the follow for a few seconds. Clicking a line seeks to it where seeking is
// possible at all (never on a stream — same honesty as the scrubber).
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool expanded: false

  signal toggleRequested()

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property var lines: service ? service.lyrics : []
  readonly property int activeIndex: service ? service.activeLyricIndex : -1
  readonly property string status: service ? service.lyricsStatus : "none"
  readonly property bool seekable: !!(service && service.canSeek)

  readonly property Item listItem: lyricList
  readonly property int listMaxHeight: Style.space(240)

  // Manual scrolling holds the auto-follow off until the hand has been still.
  property bool followHeld: false

  function scrollBy(delta) {
    if (lines.length === 0) return
    followHeld = true
    followRelease.restart()
    var target = Math.max(0, Math.min(
      lyricList.contentHeight - lyricList.height,
      lyricList.contentY + delta * Style.space(26)))
    lyricList.contentY = target
  }

  Timer {
    id: followRelease
    interval: 4000
    repeat: false
    onTriggered: { root.followHeld = false; root._follow() }
  }

  function _follow() {
    if (!expanded || followHeld) return
    if (activeIndex >= 0 && activeIndex < lines.length)
      lyricList.positionViewAtIndex(activeIndex, ListView.Center)
  }

  onActiveIndexChanged: _follow()
  onExpandedChanged: if (expanded) { followHeld = false; _follow() }

  spacing: Style.space(6)

  SectionHead {
    width: parent.width
    text: "LYRICS"
    count: root.lines.length > 0 ? String(root.lines.length) : ""

    chevron: !root.expanded
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: root.toggleRequested()
  }

  Column {
    width: parent.width
    visible: root.expanded

    ListView {
      id: lyricList
      width: parent.width
      height: Math.min(contentHeight, root.listMaxHeight)
      visible: root.lines.length > 0
      clip: true
      model: root.lines
      keyNavigationEnabled: false
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded; interactive: false }

      onMovementStarted: { root.followHeld = true; followRelease.restart() }

      delegate: Item {
        required property var modelData
        required property int index

        width: lyricList.width
        height: lineText.implicitHeight + Style.space(6)

        Text {
          id: lineText
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: modelData.text
          wrapMode: Text.WordWrap
          color: index === root.activeIndex ? Color.accent
            : index < root.activeIndex ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        MouseArea {
          anchors.fill: parent
          enabled: root.seekable
          hoverEnabled: true
          cursorShape: root.seekable ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: if (root.service) root.service.seekTo(modelData.start)
        }
      }
    }

    // The empty states, honestly named; retry only where retrying can help.
    RowSurface {
      width: parent.width
      visible: root.lines.length === 0
      foreground: root.foreground

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        enabled: root.status === "notfound"
        onClicked: if (root.service) root.service.retryLyrics()
      }

      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: root.status === "loading" ? "looking up lyrics…"
          : root.status === "notfound" ? "no lyrics found  ·  r retry"
          : "nothing playing"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
