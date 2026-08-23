import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// The server picker, 1a-style. Every Service keeps its own tunnel and
// heartbeat alive, so the states here are current and switching is instant.
Column {
  id: root

  property var services: []
  property int activeIndex: 0
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool expanded: false
  property int cursorIndex: -1

  signal toggleRequested()
  signal selectRequested(int index)

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property var active: (activeIndex >= 0 && activeIndex < services.length)
    ? services[activeIndex] : null

  function stateText(svc) {
    if (!svc) return ""
    if (svc.isPlaying) return "playing"
    if (svc.running) return "online"
    if (svc.tunnelUp) return "idle"
    return "offline"
  }

  spacing: Style.space(6)

  SectionHead {
    width: parent.width
    text: "SERVER"
    count: root.services.length > 1 ? String(root.services.length) : ""

    chevron: !root.expanded
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: root.toggleRequested()
  }

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
        text: root.active ? root.active.label : "no servers configured"
        color: root.active ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        text: root.stateText(root.active)
        color: root.active && root.active.isPlaying ? Color.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        opacity: root.active && !root.active.tunnelUp ? 0.5 : 1
      }
    }
  }

  Column {
    width: parent.width
    visible: root.expanded

    Repeater {
      model: root.services

      RowSurface {
        id: srow
        required property var modelData
        required property int index

        width: parent.width
        foreground: root.foreground
        hasCursor: index === root.cursorIndex

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.selectRequested(index)
        }

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            text: index === root.activeIndex ? "✓" : " "
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            Layout.preferredWidth: Style.space(12)
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: srow.modelData.label
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            text: root.stateText(srow.modelData)
            color: srow.modelData.isPlaying ? Color.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            opacity: srow.modelData.tunnelUp ? 1 : 0.5
          }
        }
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: root.expanded && root.services.length > 1
    text: "enter switch · wheel on bar icon cycles"
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    leftPadding: Style.space(10)
  }
}
