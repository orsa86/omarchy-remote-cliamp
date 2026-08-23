import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// The lights, 1a-style: LedFx scenes as accent action rows, then one row per
// WLED virtual with its state. Summoned with `L`, invisible otherwise —
// same treatment as the lyric sheet and the keymap.
Column {
  id: root

  property var ledfx: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool expanded: false
  property int cursorIndex: -1

  signal toggleRequested()

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property var scenes: ledfx ? ledfx.scenes : []
  readonly property var virtuals: ledfx ? ledfx.virtuals : []
  // One flat cursor list: scenes first, then virtuals — what Enter acts on.
  readonly property int rowCount: scenes.length + virtuals.length

  function activate(index) {
    if (!ledfx) return
    if (index < scenes.length) { ledfx.activateScene(scenes[index].id); return }
    var v = virtuals[index - scenes.length]
    if (v) ledfx.toggleVirtual(v.id)
  }

  spacing: Style.space(6)

  SectionHead {
    width: parent.width
    text: "LIGHTS"
    count: root.virtuals.length > 0 ? String(root.virtuals.length) : ""
    hint: root.expanded && root.ledfx && !root.ledfx.reachable ? "unreachable" : ""
    chevron: !root.expanded
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: root.toggleRequested()
  }

  Column {
    width: parent.width
    visible: root.expanded

    Repeater {
      model: root.scenes

      RowSurface {
        id: scrow
        required property var modelData
        required property int index

        width: parent.width
        foreground: root.foreground
        hasCursor: index === root.cursorIndex

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.activate(index)
        }

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: "▶ " + scrow.modelData.name
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            text: "[scene]"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    Repeater {
      model: root.virtuals

      RowSurface {
        id: vrow
        required property var modelData
        required property int index

        width: parent.width
        foreground: root.foreground
        hasCursor: index + root.scenes.length === root.cursorIndex

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.activate(index + root.scenes.length)
        }

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: vrow.modelData.name
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            text: vrow.modelData.active ? "active" : "off"
            color: vrow.modelData.active ? Color.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: root.rowCount === 0
      text: root.ledfx && root.ledfx.reachable === false
        ? "ledfx unreachable — check ledfxUrl"
        : "no lights found"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: root.rowCount > 0
      text: "enter run scene / toggle light"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      leftPadding: Style.space(10)
    }
  }
}
