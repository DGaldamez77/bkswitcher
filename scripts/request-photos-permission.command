#!/bin/zsh

echo "Requesting Photos permission from Terminal host..."
swift -e 'import Foundation; import Photos; import Dispatch; func statusName(_ status: PHAuthorizationStatus) -> String { switch status { case .notDetermined: return "notDetermined"; case .restricted: return "restricted"; case .denied: return "denied"; case .authorized: return "authorized"; case .limited: return "limited"; @unknown default: return "unknown(\(status.rawValue))" } }; func finish(_ status: PHAuthorizationStatus) { print("Photos auth status: \(statusName(status)) (raw=\(status.rawValue))"); if status == .authorized || status == .limited { exit(0) } else { exit(2) } }; let current = PHPhotoLibrary.authorizationStatus(for: .readWrite); if current == .notDetermined { PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in finish(status) }; dispatchMain() } else { finish(current) }'
status=$?

if [[ $status -ne 0 ]]; then
  echo ""
  echo "Photos permission is still not granted."
  echo "Open System Settings > Privacy & Security > Photos and allow Terminal."
fi

echo ""
echo "Press Enter to close this window."
read
exit $status
