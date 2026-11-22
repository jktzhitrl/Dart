/// Teilnehmer eines Turniers.
class Participant {
  final String id;
  final String name;

  /// Setzplatz (1 = bester). `null` = ungesetzt.
  final int? seed;
  final int? lotNumber;
  final List<Participant> members;

  const Participant({
    required this.id,
    required this.name,
    this.seed,
    this.lotNumber,
    this.members = const [],
  });

  bool represents(String playerId) => id == playerId || members.any((p) => p.id == playerId);

  Participant copyWith({String? name, int? seed, bool clearSeed = false, int? lotNumber, bool clearLot = false}) => Participant(
        id: id,
        name: name ?? this.name,
        seed: clearSeed ? null : (seed ?? this.seed),
        lotNumber: clearLot ? null : (lotNumber ?? this.lotNumber),
        members: members,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'seed': seed,
    if (lotNumber != null) 'lotNumber': lotNumber,
    if (members.isNotEmpty) 'members': members.map((p) => p.toJson()).toList(),
  };

  factory Participant.fromJson(Map<String, dynamic> j) => Participant(
        id: j['id'] as String,
        name: j['name'] as String,
        seed: (j['seed'] as num?)?.toInt(),
        lotNumber: (j['lotNumber'] as num?)?.toInt(),
        members: [
          for (final member in j['members'] as List? ?? const [])
            Participant.fromJson(Map<String, dynamic>.from(member as Map)),
        ],
      );

  @override
  String toString() => name;
}
