import 'package:immich_mobile/utils/hash.dart';
import 'package:isar/isar.dart';
import 'package:openapi/api.dart';

part 'user.g.dart';

@Collection()
class User {
  User(
    this.id,
    this.email,
    this.firstName,
    this.lastName,
    this.profileImagePath,
  );

  Id get isarId => fastHash(id);

  @Index(unique: true, replace: false, type: IndexType.hash)
  String id;
  String email;
  String firstName;
  String lastName;
  String profileImagePath;

  @override
  bool operator ==(other) {
    if (other is! User) return false;
    return id == other.id &&
        email == other.email &&
        firstName == other.firstName &&
        lastName == other.lastName &&
        profileImagePath == other.profileImagePath;
  }

  @override
  @ignore
  int get hashCode =>
      id.hashCode ^
      email.hashCode ^
      firstName.hashCode ^
      lastName.hashCode ^
      profileImagePath.hashCode;

  static User fromDto(UserResponseDto dto) {
    return User(
      dto.id,
      dto.email,
      dto.firstName,
      dto.lastName,
      dto.profileImagePath,
    );
  }

  UserResponseDto toDto() {
    return UserResponseDto(
      id: id.toString(),
      email: email,
      firstName: firstName,
      lastName: lastName,
      profileImagePath: profileImagePath,
      createdAt: '',
      isAdmin: false,
      shouldChangePassword: false,
    );
  }
}
