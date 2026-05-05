//
//  RootTabView.swift
//  EPaperNFCDemo
//

import CoreImage
import EPaperNFCSwift
import SwiftUI

struct RootTabView: View {
    @Binding var displayType: DisplayType?
    @Binding var sCurveStrength: Float
    @Binding var unsharpRadius: Float
    @Binding var unsharpIntensity: Float

    @Environment(OrientationObserver.self) private var orientation
    @State private var pendingSource: PendingSource?
    @State private var selection: TabSelection = .camera

    private enum TabSelection: Hashable { case camera, photos }

    private struct PendingSource: Identifiable {
        let id = UUID()
        let image: CIImage
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Camera", systemImage: "camera.fill", value: TabSelection.camera) {
                cameraTab
            }
            Tab("Photos", systemImage: "photo.on.rectangle.angled", value: TabSelection.photos) {
                photosTab
            }
        }
        .fullScreenCover(item: $pendingSource) { pending in
            ComposerView(
                source: pending.image,
                displayType: displayType ?? .fourPointTwoInchBlackWhiteYellowRed,
                sCurveStrength: $sCurveStrength,
                unsharpRadius: $unsharpRadius,
                unsharpIntensity: $unsharpIntensity
            )
        }
    }

    @ViewBuilder
    private var cameraTab: some View {
        NavigationStack {
            Group {
                if let displayType {
                    CameraView(
                        displayType: displayType,
                        sCurveStrength: sCurveStrength,
                        unsharpRadius: unsharpRadius,
                        unsharpIntensity: unsharpIntensity,
                        onCapture: { ci in
                            pendingSource = PendingSource(image: ci)
                        }
                    )
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { deviceToolbar }
        }
    }

    @ViewBuilder
    private var photosTab: some View {
        NavigationStack {
            Group {
                if let displayType {
                    PhotosTabView(
                        displayType: displayType,
                        onPick: { ci in
                            pendingSource = PendingSource(image: ci)
                        }
                    )
                }
            }
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { deviceToolbar }
        }
    }

    @ToolbarContentBuilder
    private var deviceToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                DeviceDetailView(displayType: $displayType)
            } label: {
                Image(systemName: "info.circle")
                    .rotationEffect(toolbarIconRotation)
            }
            .accessibilityLabel("Device info")
        }
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink {
                SendLogView()
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .rotationEffect(toolbarIconRotation)
            }
            .accessibilityLabel("Send Log")
        }
    }

    // Only rotate toolbar icons when on the Camera tab; the Photos tab is a
    // standard portrait screen and rotating its icons would be confusing.
    private var toolbarIconRotation: Angle {
        selection == .camera ? orientation.iconRotation : .degrees(0)
    }
}

struct DeviceDetailView: View {
    @Binding var displayType: DisplayType?

    var body: some View {
        Form {
            Section {
                DeviceSectionView(displayType: $displayType)
            } header: {
                Text("Device")
            } footer: {
                Text("Re-detect or change the e-Paper model. The current selection is preserved unless you change it here.")
            }

            if let displayType {
                Section {
                    SendImageView(image: EPaperNFCSwift.Image.demoImage(for: displayType))
                } header: {
                    Text("Test image")
                } footer: {
                    Text("Send a built-in demo image to verify connectivity with the e-Paper.")
                }
            }
        }
        .navigationTitle("Device")
        .navigationBarTitleDisplayMode(.inline)
    }
}
