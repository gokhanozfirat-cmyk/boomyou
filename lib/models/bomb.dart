class Bomb {
  final String id;
  final int number;
  double yPosition; // 0.0 (top) to 1.0 (bottom)
  final double xPosition; // 0.0 to 1.0
  final double speed; // fraction of screen per second

  Bomb({
    required this.id,
    required this.number,
    required this.yPosition,
    required this.xPosition,
    required this.speed,
  });
}
