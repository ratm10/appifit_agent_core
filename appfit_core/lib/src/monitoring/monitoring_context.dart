/// 모니터링에 필요한 컨텍스트 정보를 제공하는 추상 클래스
abstract class MonitoringContext {
  String get storeId;
  String get storeName;
  String get appType;
  String get appVersion;
  String get buildNumber;
  String get deviceModel;
  String get deviceManufacturer;
  String get environment;
}