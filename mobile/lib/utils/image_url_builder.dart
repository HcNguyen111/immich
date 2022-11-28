import 'package:hive/hive.dart';
import 'package:immich_mobile/shared/models/album.dart';
import 'package:openapi/api.dart';

import '../constants/hive_box.dart';

String getThumbnailUrl(
  final AssetResponseDto asset, {
  ThumbnailFormat type = ThumbnailFormat.WEBP,
}) {
  return _getThumbnailUrl(asset.id, type: type);
}

String getThumbnailCacheKey(final AssetResponseDto asset,
    {ThumbnailFormat type = ThumbnailFormat.WEBP}) {
  return _getThumbnailCacheKey(asset.id, type);
}

String _getThumbnailCacheKey(final String id, final ThumbnailFormat type) {
  if (type == ThumbnailFormat.WEBP) {
    return 'thumbnail-image-$id';
  } else {
    return '${id}_previewStage';
  }
}

String getAlbumThumbnailUrl(
  final Album album, {
  ThumbnailFormat type = ThumbnailFormat.WEBP,
}) {
  if (album.albumThumbnailAsset.value == null) {
    return '';
  }
  return _getThumbnailUrl(album.albumThumbnailAsset.value!.remoteId!,
      type: type);
}

String getAlbumThumbNailCacheKey(
  final Album album, {
  ThumbnailFormat type = ThumbnailFormat.WEBP,
}) {
  if (album.albumThumbnailAsset.value == null) {
    return '';
  }
  return _getThumbnailCacheKey(
      album.albumThumbnailAsset.value!.remoteId!, type);
}

String getImageUrl(final AssetResponseDto asset) {
  final box = Hive.box(userInfoBox);
  return '${box.get(serverEndpointKey)}/asset/file/${asset.id}?isThumb=false';
}

String getImageCacheKey(final AssetResponseDto asset) {
  return '${asset.id}_fullStage';
}

String _getThumbnailUrl(
  final String id, {
  ThumbnailFormat type = ThumbnailFormat.WEBP,
}) {
  final box = Hive.box(userInfoBox);

  return '${box.get(serverEndpointKey)}/asset/thumbnail/$id?format=${type.value}';
}
