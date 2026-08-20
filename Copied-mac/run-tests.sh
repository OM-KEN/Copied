#!/bin/bash
set -euo pipefail

TEST_BUILD_DIR=".build/tests"
mkdir -p "$TEST_BUILD_DIR"

swiftc -parse-as-library \
    PluginRuntimeSafety.swift \
    Tests/PluginSecurityTests.swift \
    -o "$TEST_BUILD_DIR/PluginSecurityTests"
"$TEST_BUILD_DIR/PluginSecurityTests"

swiftc -parse-as-library \
    MathExpressionEvaluator.swift \
    PluginActionTemplate.swift \
    ContentKind.swift \
    ContentDetection.swift \
    Detectors/MathExpressionDetector.swift \
    Tests/MathExpressionTests.swift \
    -framework AppKit \
    -o "$TEST_BUILD_DIR/MathExpressionTests"
"$TEST_BUILD_DIR/MathExpressionTests"

swift Tests/AppFilterTests.swift
swift Tests/DateTimeTests.swift

swiftc -parse-as-library \
    ContentKind.swift \
    PluginActionTemplate.swift \
    ContentDetection.swift \
    Detectors/URLDetector.swift \
    Detectors/PhoneNumberDetector.swift \
    Detectors/DateTimeDetector.swift \
    EntityDetectorWarmUp.swift \
    Tests/EntityDetectorCandidateTests.swift \
    -framework AppKit \
    -o "$TEST_BUILD_DIR/EntityDetectorCandidateTests"
"$TEST_BUILD_DIR/EntityDetectorCandidateTests"

swiftc -parse-as-library \
    DictionaryLookupService.swift \
    Tests/DictionaryWarmUpTests.swift \
    -framework CoreServices \
    -o "$TEST_BUILD_DIR/DictionaryWarmUpTests"
"$TEST_BUILD_DIR/DictionaryWarmUpTests"

swiftc -parse-as-library \
    CopySoundFeedback.swift \
    Tests/CopySoundFeedbackTests.swift \
    -framework AppKit \
    -o "$TEST_BUILD_DIR/CopySoundFeedbackTests"
"$TEST_BUILD_DIR/CopySoundFeedbackTests"

swiftc -parse-as-library \
    KeyboardShortcutSettings.swift \
    QuickTriggerModifierKeyPolicy.swift \
    QuickTriggerStateMachine.swift \
    Tests/QuickTriggerStateMachineTests.swift \
    -framework AppKit \
    -o "$TEST_BUILD_DIR/QuickTriggerStateMachineTests"
"$TEST_BUILD_DIR/QuickTriggerStateMachineTests"

swiftc -parse-as-library \
    KeyboardShortcutSettings.swift \
    QuickTriggerModifierKeyPolicy.swift \
    QuickTriggerStateMachine.swift \
    GlobalMouseEventTapRecoveryPolicy.swift \
    GlobalMouseEventCoordinator.swift \
    QuickTriggerCoordinator.swift \
    Tests/QuickTriggerCoordinatorTests.swift \
    -framework AppKit \
    -framework CoreGraphics \
    -o "$TEST_BUILD_DIR/QuickTriggerCoordinatorTests"
"$TEST_BUILD_DIR/QuickTriggerCoordinatorTests"

swiftc -parse-as-library \
    AppUpdateModels.swift \
    Tests/AppUpdateModelsTests.swift \
    -o "$TEST_BUILD_DIR/AppUpdateModelsTests"
"$TEST_BUILD_DIR/AppUpdateModelsTests"

swiftc -parse-as-library \
    AppUpdateModels.swift \
    AppUpdateService.swift \
    Tests/AppUpdateServiceTests.swift \
    -o "$TEST_BUILD_DIR/AppUpdateServiceTests"
"$TEST_BUILD_DIR/AppUpdateServiceTests"

swiftc -parse-as-library \
    ApplicationRelauncher.swift \
    Tests/ApplicationRelauncherTests.swift \
    -framework AppKit \
    -o "$TEST_BUILD_DIR/ApplicationRelauncherTests"
"$TEST_BUILD_DIR/ApplicationRelauncherTests"

swiftc -parse-as-library \
    MetadataAutoScrollMetrics.swift \
    Tests/MetadataAutoScrollMetricsTests.swift \
    -o "$TEST_BUILD_DIR/MetadataAutoScrollMetricsTests"
"$TEST_BUILD_DIR/MetadataAutoScrollMetricsTests"

swiftc -parse-as-library \
    GlobalMouseEventTapRecoveryPolicy.swift \
    CopyGestureEventSequence.swift \
    MouseButtonRecordingStateMachine.swift \
    AppUpdateModels.swift \
    LitheIntegration.swift \
    Tests/InteractionWiringTests.swift \
    -framework AppKit \
    -framework CoreGraphics \
    -o "$TEST_BUILD_DIR/InteractionWiringTests"
"$TEST_BUILD_DIR/InteractionWiringTests"

swiftc -parse-as-library \
    CopyGesturePermissionPolicy.swift \
    Tests/CopyGesturePermissionPolicyTests.swift \
    -o "$TEST_BUILD_DIR/CopyGesturePermissionPolicyTests"
"$TEST_BUILD_DIR/CopyGesturePermissionPolicyTests"

swiftc -parse-as-library \
    ClipboardTextPolicy.swift \
    ToastCommand.swift \
    ToastPanel.swift \
    Tests/ToastCommandTests.swift \
    -framework AppKit \
    -framework SwiftUI \
    -o "$TEST_BUILD_DIR/ToastCommandTests"
"$TEST_BUILD_DIR/ToastCommandTests"

swiftc -parse-as-library \
    ClipboardTextPolicy.swift \
    PopupPresentationSettings.swift \
    Tests/PopupPresentationSettingsTests.swift \
    -o "$TEST_BUILD_DIR/PopupPresentationSettingsTests"
"$TEST_BUILD_DIR/PopupPresentationSettingsTests"

echo "All tests passed"
