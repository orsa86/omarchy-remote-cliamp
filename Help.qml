import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// The keymap sheet, on the native player's own key: `?` (or Ctrl+K). Keys in
// accent at normal weight, descriptions dim — a two-column grid per group.
Column {
  id: root

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool expanded: false

  signal toggleRequested()

  readonly property color dim: Qt.darker(foreground, 1.4)

  readonly property var groups: [
    { title: "PLAYBACK", keys: [
      ["space / enter", "play or pause"],
      ["n · b", "next · previous"],
      ["h · l", "seek ±5 s (not on radio)"],
      ["+ · -", "volume ±1 dB"],
      ["s · r", "shuffle · repeat"],
      ["f", "start daemon when idle"]
    ]},
    { title: "SECTIONS", keys: [
      ["/", "search / focus field"],
      ["o", "server picker"],
      ["A", "queue"],
      ["y", "lyrics · r there retries"],
      ["L", "lights (LedFx)"],
      ["? · ctrl+k", "this keymap"],
      ["esc", "field → section → close"]
    ]},
    { title: "LISTS", keys: [
      ["j/k · ctrl+n/p", "move cursor"],
      ["ctrl+u/d", "page (also pgup/pgdn)"],
      ["enter", "play / open"],
      ["a · q · r-click", "queue, no interrupt"],
      ["backspace", "back out of drill-down"]
    ]},
    { title: "QUEUE ROWS", keys: [
      ["enter", "jump to track"],
      ["x · right click", "remove"],
      ["[ · ]", "move row up / down"]
    ]},
    { title: "SEARCH", keys: [
      ["<text>", "library, fuzzy matched"],
      ["r:", "server's radio stations"],
      ["r: <query>", "Radio Browser search"],
      ["p:", "cliamp sources (spotify, …)"],
      ["ctrl+w · ctrl+u", "delete word · clear line"]
    ]},
    { title: "BAR ICON", keys: [
      ["click · r-click", "panel · play-pause"],
      ["wheel", "switch server"],
      ["super+shift+u", "toggle panel"]
    ]}
  ]

  spacing: Style.space(6)

  SectionHead {
    width: parent.width
    text: "KEYS"
    hint: root.expanded ? "esc close" : "?"
    chevron: !root.expanded
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: root.toggleRequested()
  }

  Column {
    width: parent.width
    spacing: Style.space(10)
    visible: root.expanded
    leftPadding: Style.space(10)

    Repeater {
      model: root.groups

      Column {
        required property var modelData
        width: parent.width - Style.space(10)
        spacing: Style.space(3)

        Text {
          textFormat: Text.PlainText
          text: modelData.title
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
        }

        Repeater {
          model: modelData.keys

          RowLayout {
            required property var modelData
            width: parent.width
            spacing: Style.space(14)

            Text {
              textFormat: Text.PlainText
              text: modelData[0]
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              Layout.preferredWidth: Style.space(120)
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              text: modelData[1]
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              Layout.fillWidth: true
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }
}
