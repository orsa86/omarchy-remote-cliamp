import QtQuick
import qs.Commons

// Variant-1a list row surface: quiet until it matters. Hover is a 4% fg wash,
// the keyboard cursor an 8% wash plus a 2px accent inset on the left edge,
// and a playing row colors its text accent with no fill at all (the caller
// binds text colors off `playing`). Drop-in for where CursorSurface stood.
Rectangle {
  id: root

  property color foreground: Color.foreground
  property bool hasCursor: false
  property bool playing: false
  readonly property alias hovered: area.containsMouse

  height: Style.space(26)
  color: hasCursor ? Qt.alpha(foreground, 0.08)
    : area.containsMouse ? Qt.alpha(foreground, 0.04)
    : "transparent"

  Behavior on color { ColorAnimation { duration: 60 } }

  Rectangle {
    width: 2
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    color: Color.accent
    visible: root.hasCursor
  }

  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
  }
}
