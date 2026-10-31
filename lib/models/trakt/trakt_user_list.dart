/// One of the signed-in user's personal Trakt lists (`/users/me/lists`).
class TraktUserList {
  final int traktId;
  final String? slug;
  final String name;
  final String? description;

  const TraktUserList({required this.traktId, this.slug, required this.name, this.description});

  /// Null when the payload has no numeric Trakt id to address the list by.
  static TraktUserList? fromJson(Map<String, dynamic> json) {
    final ids = json['ids'];
    final id = ids is Map ? ids['trakt'] : null;
    final name = json['name'];
    if (id is! int || name is! String) return null;
    final slug = ids is Map ? ids['slug'] : null;
    final description = json['description'];
    return TraktUserList(
      traktId: id,
      slug: slug is String ? slug : null,
      name: name,
      description: description is String ? description : null,
    );
  }
}
