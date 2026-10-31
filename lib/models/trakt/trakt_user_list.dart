/// A Trakt list: one of the user's own (`/users/me/lists`), a liked one
/// (`/users/likes/lists`) or a public one (`/lists/trending`).
class TraktUserList {
  final int traktId;
  final String? slug;
  final String name;
  final String? description;

  /// The owner's user slug, for `/users/{user}/lists/{id}/items`.
  final String? userSlug;
  final int? itemCount;
  final int? likeCount;

  const TraktUserList({
    required this.traktId,
    this.slug,
    required this.name,
    this.description,
    this.userSlug,
    this.itemCount,
    this.likeCount,
  });

  /// Null when the payload has no numeric Trakt id to address the list by.
  static TraktUserList? fromJson(Map<String, dynamic> json) {
    final ids = json['ids'];
    final id = ids is Map ? ids['trakt'] : null;
    final name = json['name'];
    if (id is! int || name is! String) return null;
    final slug = ids is Map ? ids['slug'] : null;
    final description = json['description'];
    final user = json['user'];
    final userIds = user is Map ? user['ids'] : null;
    final userSlug = userIds is Map ? userIds['slug'] : null;
    final itemCount = json['item_count'];
    final likeCount = json['likes'];
    return TraktUserList(
      traktId: id,
      slug: slug is String ? slug : null,
      name: name,
      description: description is String ? description : null,
      userSlug: userSlug is String ? userSlug : null,
      itemCount: itemCount is int ? itemCount : null,
      likeCount: likeCount is int ? likeCount : null,
    );
  }
}
