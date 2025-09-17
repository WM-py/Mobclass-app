class AlunoModel {
  final String nome;
  final String turma;

  AlunoModel({required this.nome, required this.turma});

  factory AlunoModel.fromMap(Map<String, dynamic> map) {
    return AlunoModel(
      nome: map['nome'] ?? '',
      turma: map['turma'] ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'nome': nome,
      'turma': turma,
    };
  }
}

