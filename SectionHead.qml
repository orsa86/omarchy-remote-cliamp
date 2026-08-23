import QtQuick
import qs.Commons

// Variant-1a section header: UPPERCASE dim label, a 1px leader line filling the
// middle, and a right-aligned count or key hint. Replaces the old
// PanelSectionHeader + PanelSeparator pair everywhere.
Item {
  id: root

  property string text: ""
  property string count: ""
  property string hint: ""
  // Chevron only on rows that drill in.
  property bool chevron: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal clicked()

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color leader: Qt.alpha(foreground, 0.12)

  implicitHeight: Math.max(label.implicitHeight, Style.space(14))

  Row {
    anchors.fill: parent
    spacing: Style.space(10)

    Text {
      id: label
      textFormat: Text.PlainText
      text: root.text
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
      anchors.verticalCenter: parent.verticalCenter
    }

    Rectangle {
      width: parent.width - label.implicitWidth - right.implicitWidth
        - parent.spacing * 2
      height: 1
      color: root.leader
      anchors.verticalCenter: parent.verticalCenter
    }

    Row {
      id: right
      spacing: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter

      Text {
        textFormat: Text.PlainText
        visible: root.count.length > 0
        text: root.count
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1.2
      }

      Text {
        textFormat: Text.PlainText
        visible: root.hint.length > 0 || root.chevron
        text: root.hint.length > 0
          ? root.hint + (root.chevron ? "  ›" : "")
          : "›"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    anchors.margins: -Style.space(2)
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
