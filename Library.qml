import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// The library, 1a-style: leader-line header, a breadcrumb whose current
// segment keeps full foreground, a quiet bordered search field, and rows
// tagged with their kind as literal [brackets]. Action rows (play-all) are
// the only accent text in the list.
Column {
  id: root

  property var service: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool expanded: false
  property int cursorIndex: -1

  signal toggleRequested()
  signal moveRequested(int delta)
  signal activateRequested()

  readonly property bool searchFocused: search.activeFocus
  readonly property Item listItem: albumList

  function focusSearch() { search.forceActiveFocus() }

  function deleteWordBefore() {
    var pos = search.cursorPosition
    var text = search.text
    var at = pos
    while (at > 0 && text.charAt(at - 1) === " ") at--
    while (at > 0 && text.charAt(at - 1) !== " ") at--
    if (at < pos) search.remove(at, pos)
  }

  function clearBeforeCursor() {
    if (search.cursorPosition > 0) search.remove(0, search.cursorPosition)
  }

  onExpandedChanged: expanded ? search.forceActiveFocus() : root.forceActiveFocus()

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property var results: service ? service.results : []
  readonly property bool cliampRunning: !!(service && service.running)

  readonly property int listMaxHeight: Style.space(240)

  onCursorIndexChanged: if (cursorIndex >= 0) albumList.positionViewAtIndex(cursorIndex, ListView.Contain)

  function kindTag(kind) {
    if (kind === "albumsong") return "song"
    if (kind === "artistplay" || kind === "playall") return ""
    return String(kind || "")
  }

  spacing: Style.space(6)

  SectionHead {
    width: parent.width
    text: "LIBRARY"
    count: root.results.length > 0 ? String(root.results.length) : ""

    chevron: !root.expanded
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: root.toggleRequested()
  }

  Column {
    width: parent.width
    spacing: Style.space(6)
    visible: root.expanded

    // Breadcrumb: the path in dim, the segment you are IN at full strength.
    Row {
      width: parent.width
      visible: !!(root.service && root.service.breadcrumb.length > 0)
      spacing: 0

      Text {
        textFormat: Text.PlainText
        text: {
          if (!root.service) return ""
          var parts = root.service.breadcrumb.split(" / ")
          parts.pop()
          return ("NAVIDROME / " + (parts.length > 0 ? parts.join(" / ") + " / " : "")).toUpperCase()
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1.2
      }

      Text {
        textFormat: Text.PlainText
        text: {
          if (!root.service) return ""
          var parts = root.service.breadcrumb.split(" / ")
          return String(parts[parts.length - 1] || "").toUpperCase()
        }
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1.2
        elide: Text.ElideRight
      }
    }

    TextField {
      id: search
      width: parent.width
      placeholderText: "search · r: radio · p: sources"
      foreground: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      verticalPadding: Style.space(7)

      background: Rectangle {
        color: Qt.alpha(root.foreground, 0.04)
        border.width: 1
        border.color: search.activeFocus
          ? Qt.alpha(root.foreground, 0.4)
          : Qt.alpha(root.foreground, 0.12)
      }

      Keys.onEscapePressed: root.focus = true
      Keys.onUpPressed: root.moveRequested(-1)
      Keys.onDownPressed: root.moveRequested(1)
      Keys.onReturnPressed: root.activateRequested()
      Keys.onEnterPressed: root.activateRequested()
      Keys.onPressed: function (event) {
        if (!(event.modifiers & Qt.ControlModifier)) return
        if (event.key === Qt.Key_N) { root.moveRequested(1); event.accepted = true }
        else if (event.key === Qt.Key_P) { root.moveRequested(-1); event.accepted = true }
        else if (event.key === Qt.Key_W) { root.deleteWordBefore(); event.accepted = true }
        else if (event.key === Qt.Key_U) { root.clearBeforeCursor(); event.accepted = true }
      }

      onTextChanged: searchDebounce.restart()
    }

    Timer {
      id: searchDebounce
      interval: 260
      repeat: false
      onTriggered: if (root.service) root.service.search(search.text)
    }

    ListView {
      id: albumList
      width: parent.width
      height: Math.min(contentHeight, root.listMaxHeight)
      clip: true
      model: root.results
      keyNavigationEnabled: false
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      onCountChanged: if (root.cursorIndex >= 0) positionViewAtIndex(root.cursorIndex, ListView.Contain)

      delegate: RowSurface {
        id: lrow
        required property var modelData
        required property int index

        readonly property bool isAction: modelData.kind === "playall" || modelData.kind === "artistplay"
        readonly property bool isBack: modelData.kind === "back"

        width: albumList.width
        foreground: root.foreground
        hasCursor: index === root.cursorIndex

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          onClicked: function (mouse) {
            if (!root.service) return
            if (mouse.button === Qt.RightButton) root.service.queueResult(lrow.modelData)
            else root.service.playResult(lrow.modelData)
          }
        }

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: (lrow.modelData.artist && !lrow.isAction && !lrow.isBack
              ? lrow.modelData.artist + " · " : "") + lrow.modelData.name
            color: lrow.isAction ? Color.accent : lrow.isBack ? root.dim : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            visible: text.length > 0
            text: {
              if (lrow.isAction) return lrow.modelData.kind === "playall" ? "p" : ""
              var k = root.kindTag(lrow.modelData.kind)
              return k.length > 0 ? "[" + k + "]" : ""
            }
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
      text: "nothing matched"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      visible: root.results.length === 0
    }
  }

  // Only offered when nothing owns the remote socket: bring the daemon up
  // over ssh, since a terminal player over there is not something this panel
  // can open.
  RowSurface {
    width: parent.width
    visible: !root.cliampRunning
    foreground: root.foreground

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (root.service) root.service.openPlayer()
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: "start cliamp daemon on server"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        text: "f  ›"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
