#!/bin/bash
set -euo pipefail

TEST_BUILD_DIR=".build/tests"
mkdir -p "$TEST_BUILD_DIR"

swiftc -O -parse-as-library \
    ClipboardPipeline.swift \
    PluginActionTemplate.swift \
    ContentKind.swift \
    ContentDetection.swift \
    ClipboardDetectionDisplayFacts.swift \
    RelativeDateDescription.swift \
    AppLanguage.swift \
    DetectionRegistry.swift \
    MathExpressionEvaluator.swift \
    Detectors/ColorDetector.swift \
    Detectors/URLDetector.swift \
    Detectors/PhoneNumberDetector.swift \
    Detectors/EmailDetector.swift \
    Detectors/FilePathDetector.swift \
    Detectors/MathExpressionDetector.swift \
    Detectors/DateTimeDetector.swift \
    Detectors/ChineseCharDetector.swift \
    Detectors/EnglishPhraseDetector.swift \
    Detectors/HTMLDetector.swift \
    Detectors/SwiftDetector.swift \
    Detectors/PythonDetector.swift \
    Detectors/JavaScriptDetector.swift \
    Detectors/CSSDetector.swift \
    FilePreviewGenerator.swift \
    Tests/ClipboardPipelineTests.swift \
    -framework AppKit \
    -framework CoreGraphics \
    -framework QuickLookThumbnailing \
    -o "$TEST_BUILD_DIR/ClipboardPipelineTests"
"$TEST_BUILD_DIR/ClipboardPipelineTests"

swiftc -O -parse-as-library \
    ClipboardPipeline.swift \
    ClipboardContentEnrichment.swift \
    Tests/ClipboardBaseReaderTests.swift \
    -framework AppKit \
    -framework CoreGraphics \
    -framework ImageIO \
    -o "$TEST_BUILD_DIR/ClipboardBaseReaderTests"
"$TEST_BUILD_DIR/ClipboardBaseReaderTests"

swiftc -O -parse-as-library \
    Tests/InstantClipboardFeedbackTests.swift \
    -o "$TEST_BUILD_DIR/InstantClipboardFeedbackTests"
"$TEST_BUILD_DIR/InstantClipboardFeedbackTests"

swiftc -O -parse-as-library \
    TemporaryTextExport.swift \
    Tests/TemporaryTextExportTests.swift \
    -framework AppKit \
    -o "$TEST_BUILD_DIR/TemporaryTextExportTests"
"$TEST_BUILD_DIR/TemporaryTextExportTests"

swiftc -O -parse-as-library \
    PluginRuntimeSafety.swift \
    Tests/PluginSecurityTests.swift \
    -o "$TEST_BUILD_DIR/PluginSecurityTests"
"$TEST_BUILD_DIR/PluginSecurityTests"

swiftc -O -parse-as-library \
    MathExpressionEvaluator.swift \
    PluginActionTemplate.swift \
    ContentKind.swift \
    ContentDetection.swift \
    Detectors/MathExpressionDetector.swift \
    Tests/MathExpressionTests.swift \
    -framework AppKit \
    -o "$TEST_BUILD_DIR/MathExpressionTests"
"$TEST_BUILD_DIR/MathExpressionTests"

swiftc -O -parse-as-library \
    AppFilterSettings.swift \
    Tests/AppFilterTests.swift \
    -framework AppKit \
    -o "$TEST_BUILD_DIR/AppFilterTests"
"$TEST_BUILD_DIR/AppFilterTests"

swiftc -O -parse-as-library \
    DetectionRegistry.swift \
    AppLanguage.swift \
    MathExpressionEvaluator.swift \
    Detectors/ColorDetector.swift \
    Detectors/URLDetector.swift \
    Detectors/PhoneNumberDetector.swift \
    Detectors/EmailDetector.swift \
    Detectors/FilePathDetector.swift \
    Detectors/MathExpressionDetector.swift \
    Detectors/ChineseCharDetector.swift \
    Detectors/EnglishPhraseDetector.swift \
    Detectors/HTMLDetector.swift \
    Detectors/SwiftDetector.swift \
    Detectors/PythonDetector.swift \
    Detectors/JavaScriptDetector.swift \
    Detectors/CSSDetector.swift \
    ContentKind.swift \
    PluginActionTemplate.swift \
    ContentDetection.swift \
    Detectors/DateTimeDetector.swift \
    Tests/DateTimeTests.swift \
    -framework AppKit \
    -o "$TEST_BUILD_DIR/DateTimeTests"
"$TEST_BUILD_DIR/DateTimeTests"

swiftc -O -parse-as-library \
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

swiftc -O -parse-as-library \
    DictionaryLookupService.swift \
    Tests/DictionaryWarmUpTests.swift \
    -framework CoreServices \
    -o "$TEST_BUILD_DIR/DictionaryWarmUpTests"
"$TEST_BUILD_DIR/DictionaryWarmUpTests"

swiftc -O -parse-as-library \
    CopySoundFeedback.swift \
    Tests/CopySoundFeedbackTests.swift \
    -framework AppKit \
    -o "$TEST_BUILD_DIR/CopySoundFeedbackTests"
"$TEST_BUILD_DIR/CopySoundFeedbackTests"

swiftc -O -parse-as-library \
    KeyboardShortcutSettings.swift \
    QuickTriggerModifierKeyPolicy.swift \
    QuickTriggerStateMachine.swift \
    Tests/QuickTriggerStateMachineTests.swift \
    -framework AppKit \
    -o "$TEST_BUILD_DIR/QuickTriggerStateMachineTests"
"$TEST_BUILD_DIR/QuickTriggerStateMachineTests"

swiftc -O -parse-as-library \
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

swiftc -O -parse-as-library \
    AppUpdateModels.swift \
    Tests/AppUpdateModelsTests.swift \
    -o "$TEST_BUILD_DIR/AppUpdateModelsTests"
"$TEST_BUILD_DIR/AppUpdateModelsTests"

swiftc -O -parse-as-library \
    AppUpdateModels.swift \
    AppUpdateService.swift \
    Tests/AppUpdateServiceTests.swift \
    -o "$TEST_BUILD_DIR/AppUpdateServiceTests"
"$TEST_BUILD_DIR/AppUpdateServiceTests"

swiftc -O -parse-as-library \
    FeedbackSupport.swift \
    Tests/FeedbackSupportTests.swift \
    -o "$TEST_BUILD_DIR/FeedbackSupportTests"
"$TEST_BUILD_DIR/FeedbackSupportTests"

swiftc -O -parse-as-library \
    ApplicationRelauncher.swift \
    Tests/ApplicationRelauncherTests.swift \
    -framework AppKit \
    -o "$TEST_BUILD_DIR/ApplicationRelauncherTests"
"$TEST_BUILD_DIR/ApplicationRelauncherTests"

swiftc -O -parse-as-library \
    MetadataAutoScrollMetrics.swift \
    Tests/MetadataAutoScrollMetricsTests.swift \
    -o "$TEST_BUILD_DIR/MetadataAutoScrollMetricsTests"
"$TEST_BUILD_DIR/MetadataAutoScrollMetricsTests"

swiftc -O -parse-as-library \
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

swiftc -O -parse-as-library \
    CopyGesturePermissionPolicy.swift \
    Tests/CopyGesturePermissionPolicyTests.swift \
    -o "$TEST_BUILD_DIR/CopyGesturePermissionPolicyTests"
"$TEST_BUILD_DIR/CopyGesturePermissionPolicyTests"

swiftc -O -parse-as-library \
    ClipboardPipeline.swift \
    ClipboardTextPolicy.swift \
    ToastCommand.swift \
    ToastPanel.swift \
    Tests/ToastCommandTests.swift \
    -framework AppKit \
    -framework SwiftUI \
    -o "$TEST_BUILD_DIR/ToastCommandTests"
"$TEST_BUILD_DIR/ToastCommandTests"

swiftc -O -parse-as-library \
    ClipboardTextPolicy.swift \
    PopupPresentationSettings.swift \
    Tests/PopupPresentationSettingsTests.swift \
    -o "$TEST_BUILD_DIR/PopupPresentationSettingsTests"
"$TEST_BUILD_DIR/PopupPresentationSettingsTests"

swiftc -O -D COPIED_TESTING -parse-as-library \
    *.swift Detectors/*.swift Tests/AppBehaviorTests.swift \
    -target arm64-apple-macosx14.0 \
    -o "$TEST_BUILD_DIR/AppBehaviorTests"
"$TEST_BUILD_DIR/AppBehaviorTests"

bash Tests/BuildScriptTests.sh

echo "All tests passed"
