import 'package:immich_mobile/shared/models/asset.dart';
import 'package:immich_mobile/shared/models/user.dart';
import 'package:isar/isar.dart';
import 'package:openapi/api.dart';

part 'album.g.dart';

@Collection()
class Album {
  Album(
    this.remoteId,
    this.name,
    this.createdAt,
    this.modifiedAt,
    this.assetCount,
    this.shared,
  );

  Id id = Isar.autoIncrement;
  @Index(unique: false, replace: false, type: IndexType.hash)
  String? remoteId;
  @Index(unique: false, replace: false, type: IndexType.hash)
  String? localId;
  String name;
  DateTime createdAt;
  DateTime modifiedAt;
  int assetCount;
  bool shared;
  final IsarLink<User> owner = IsarLink<User>();
  final IsarLink<Asset> albumThumbnailAsset = IsarLink<Asset>();
  final IsarLinks<User> sharedUsers = IsarLinks<User>();
  final IsarLinks<Asset> assets = IsarLinks<Asset>();

  @ignore
  get isRemote => remoteId != null;

  @ignore
  AlbumResponseDto? _dto;

  @override
  bool operator ==(other) {
    if (other is! Album) return false;
    return id == other.id &&
        remoteId == other.remoteId &&
        localId == other.localId &&
        name == other.name &&
        createdAt == other.createdAt &&
        modifiedAt == other.modifiedAt &&
        shared == other.shared;
  }

  @override
  @ignore
  int get hashCode =>
      id.hashCode ^
      remoteId.hashCode ^
      localId.hashCode ^
      name.hashCode ^
      createdAt.hashCode ^
      modifiedAt.hashCode ^
      shared.hashCode;

  static Future<Album> fromDto(AlbumResponseDto dto, Isar db) async {
    final Album a = Album(
      dto.id,
      dto.albumName,
      DateTime.parse(dto.createdAt),
      DateTime.parse(dto.modifiedAt),
      dto.assetCount,
      dto.shared,
    );
    a.owner.value = await db.users.getById(dto.ownerId);
    final users = await db.users
        .getAllById(dto.sharedUsers.map((e) => e.id).toList(growable: false));
    a.sharedUsers.addAll(users.where((e) => e != null).map((e) => e!));
    a.albumThumbnailAsset.value = await db.assets
        .where()
        .remoteIdEqualTo(dto.albumThumbnailAssetId)
        .findFirst();
    final assets =
        await db.assets.getAllByRemoteId(dto.assets.map((e) => e.id));
    a.assets.addAll(assets);
    return a;
  }

  AlbumResponseDto toDto({
    bool withAssets = false,
    bool withSharedUsers = false,
  }) {
    _dto ??= AlbumResponseDto(
      id: remoteId!,
      assetCount: assets.length,
      albumName: name,
      ownerId: owner.value!.id,
      assets: withAssets
          ? assets.map((e) => e.remote!).toList(growable: false)
          : const [],
      createdAt: createdAt.toIso8601String(),
      modifiedAt: modifiedAt.toIso8601String(),
      shared: shared,
      sharedUsers: withSharedUsers
          ? sharedUsers.map((e) => e.toDto()).toList(growable: false)
          : const [],
      albumThumbnailAssetId: albumThumbnailAsset.value!.remoteId,
    );
    return _dto!;
  }

  Future<void> storeToDb(Isar db) {
    return db.writeTxn(() async {
      await db.albums.put(this);
      await sharedUsers.save();
      await assets.save();
      await owner.save();
      await albumThumbnailAsset.save();
    });
  }
}
