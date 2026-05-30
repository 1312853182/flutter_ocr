class PressPlate {
  String name;
  int row;
  int col;
  String description;

  PressPlate({
    required this.name,
    required this.description,
    this.row = 0,
    this.col = 0,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'row': row,
    'col': col,
    'description': description,
  };
}
