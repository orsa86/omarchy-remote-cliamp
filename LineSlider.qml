import QtQuick
import qs.Commons

// Variant-1a slider: a 2px line with a small square knob. Rail is the separator
// wash, fill and knob plain foreground. Left drag sets, right click resets.
Item {
  id: root

  property real minimum: 0
  property real maximum: 100
  property real value: 0
  property color foreground: Color.foreground
  property bool enabled: true

  signal moved(real value)
  signal rightClicked()

  readonly property real _span: maximum - minimum
  readonly property real _frac: _span > 0 ? Math.max(0, Math.min(1, (value - minimum) / _span)) : 0

  implicitHeight: Style.space(14)
  opacity: enabled ? 1 : 0.4

  Rectangle {
    id: rail
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    height: 2
    color: Qt.alpha(root.foreground, 0.12)
  }

  Rectangle {
    anchors.left: rail.left
    anchors.verticalCenter: parent.verticalCenter
    width: rail.width * root._frac
    height: 2
    color: root.foreground
  }

  Rectangle {
    x: Math.max(0, Math.min(rail.width - width, rail.width * root._frac - width / 2))
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(8)
    height: Style.space(8)
    color: root.foreground
  }

  MouseArea {
    anchors.fill: parent
    anchors.topMargin: -Style.space(6)
    anchors.bottomMargin: -Style.space(6)
    enabled: root.enabled
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor

    function apply(mx) {
      var frac = Math.max(0, Math.min(1, mx / width))
      root.moved(root.minimum + frac * root._span)
    }

    onPressed: function (mouse) {
      if (mouse.button === Qt.RightButton) { root.rightClicked(); return }
      apply(mouse.x)
    }
    onPositionChanged: function (mouse) {
      if (mouse.buttons & Qt.LeftButton) apply(mouse.x)
    }
  }
}
