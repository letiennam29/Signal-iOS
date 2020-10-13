//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import SignalRingRTC

// TODO: Eventually add 1:1 call support to this view
// and replace CallViewController
class GroupCallViewController: UIViewController {
    private let thread: TSGroupThread?
    private let call: SignalCall
    private var groupCall: GroupCall { call.groupCall }
    private lazy var callControls = CallControls(call: call, delegate: self)
    private lazy var callHeader = CallHeader(call: call, delegate: self)
    private var callService: CallService { AppEnvironment.shared.callService }

    private lazy var videoGrid = GroupCallVideoGrid(call: call)
    private lazy var videoOverflow = GroupCallVideoOverflow(call: call, delegate: self)

    private let localMemberView = LocalGroupMemberView()
    private let speakerView = RemoteGroupMemberView()

    private var speakerPage = UIView()

    private let scrollView = UIScrollView()

    init(call: SignalCall) {
        // TODO: Eventually unify UI for group and individual calls
        owsAssertDebug(call.isGroupCall)

        self.call = call
        self.thread = Self.databaseStorage.uiRead { transaction in
            let threadId = TSGroupThread.threadId(fromGroupId: call.groupCall.groupId)
            return TSGroupThread.anyFetchGroupThread(uniqueId: threadId, transaction: transaction)
        }

        super.init(nibName: nil, bundle: nil)

        call.addObserverAndSyncState(observer: self)
    }

    @discardableResult
    @objc(presentLobbyForThread:)
    class func presentLobby(thread: TSGroupThread) -> Bool {
        guard tsAccountManager.isOnboarded() else {
            Logger.warn("aborting due to user not being onboarded.")
            OWSActionSheets.showActionSheet(title: NSLocalizedString(
                "YOU_MUST_COMPLETE_ONBOARDING_BEFORE_PROCEEDING",
                comment: "alert body shown when trying to use features in the app before completing registration-related setup."
            ))
            return false
        }

        guard let frontmostViewController = UIApplication.shared.frontmostViewController else {
            owsFailDebug("could not identify frontmostViewController")
            return false
        }

        frontmostViewController.ows_askForMicrophonePermissions { granted in
            guard granted == true else {
                Logger.warn("aborting due to missing microphone permissions.")
                frontmostViewController.ows_showNoMicrophonePermissionActionSheet()
                return
            }

            frontmostViewController.ows_askForCameraPermissions { granted in
                guard granted else {
                    Logger.warn("aborting due to missing camera permissions.")
                    return
                }

                guard let groupCall = AppEnvironment.shared.callService.buildAndConnectGroupCallIfPossible(
                        thread: thread
                ) else {
                    return owsFailDebug("Failed to build g roup call")
                }

                let vc = GroupCallViewController(call: groupCall)
                vc.modalTransitionStyle = .crossDissolve

                OWSWindowManager.shared.startCall(vc)
            }
        }

        return true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = UIView()

        view.backgroundColor = .ows_black

        scrollView.delegate = self
        view.addSubview(scrollView)
        scrollView.isPagingEnabled = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.autoPinEdgesToSuperviewEdges()

        view.addSubview(callHeader)
        callHeader.autoPinWidthToSuperview()
        callHeader.autoPinEdge(toSuperviewEdge: .top)

        view.addSubview(callControls)
        callControls.autoPinWidthToSuperview()
        callControls.autoPinEdge(toSuperviewEdge: .bottom)

        view.addSubview(videoOverflow)
        videoOverflow.autoPinEdge(toSuperviewEdge: .leading)
        videoOverflow.autoPinEdge(
            toSuperviewEdge: .trailing,
            withInset: GroupCallVideoOverflow.itemHeight * ReturnToCallViewController.pipSize.aspectRatio + 4
        )
        videoOverflow.autoPinEdge(.bottom, to: .top, of: callControls)

        scrollView.addSubview(videoGrid)
        scrollView.addSubview(speakerPage)

        updateCallUI()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        coordinator.animate(alongsideTransition: nil) { _ in
            self.updateScrollViewFrames()
        }
    }

    private var hasOverflowMembers: Bool { videoGrid.maxItems < groupCall.joinedRemoteDeviceStates.count }

    private func updateScrollViewFrames() {
        view.layoutIfNeeded()

        if groupCall.joinedGroupMembers.count < 3 || groupCall.localDevice.joinState != .joined {
            videoGrid.frame = .zero
            videoGrid.isHidden = true
            speakerPage.frame = CGRect(
                x: 0,
                y: 0,
                width: view.width,
                height: view.height
            )
            scrollView.contentSize = CGSize(width: view.width, height: view.height)
            scrollView.contentOffset = .zero
            scrollView.isScrollEnabled = false
        } else {
            let wasVideoGridHidden = videoGrid.isHidden

            scrollView.isScrollEnabled = true
            videoGrid.isHidden = false
            videoGrid.frame = CGRect(
                x: 0,
                y: view.safeAreaInsets.top,
                width: view.width,
                height: view.height - view.safeAreaInsets.top - callControls.height - (hasOverflowMembers ? videoOverflow.height : 0)
            )
            speakerPage.frame = CGRect(
                x: 0,
                y: view.height,
                width: view.width,
                height: view.height
            )
            scrollView.contentSize = CGSize(width: view.width, height: view.height * 2)

            if wasVideoGridHidden {
                scrollView.contentOffset = .zero
            }
        }
    }

    func updateCallUI() {
        let localDevice = groupCall.localDevice

        localMemberView.configure(
            device: localDevice,
            session: call.videoCaptureController.captureSession,
            isFullScreen: localDevice.joinState != .joined || groupCall.joinedGroupMembers.count < 2
        )

        switch localDevice.connectionState {
        case .connected:
            break
        case .connecting, .disconnected, .reconnecting:
            // todo: show spinner
            return
        }

        speakerPage.subviews.forEach { $0.removeFromSuperview() }
        localMemberView.removeFromSuperview()

        switch localDevice.joinState {
        case .joined:
            if let speakerState = groupCall.joinedRemoteDeviceStates.first {
                speakerPage.addSubview(speakerView)
                speakerView.autoPinEdgesToSuperviewEdges()
                speakerView.configure(device: speakerState, isFullScreen: true)

                view.addSubview(localMemberView)

                if groupCall.joinedGroupMembers.count > 2 {
                    localMemberView.autoSetDimension(.height, toSize: GroupCallVideoOverflow.itemHeight)
                    localMemberView.autoSetDimension(
                        .width,
                        toSize: GroupCallVideoOverflow.itemHeight * ReturnToCallViewController.pipSize.aspectRatio
                    )
                    localMemberView.autoPinEdge(.top, to: .top, of: videoOverflow)
                } else {
                    localMemberView.autoSetDimensions(to: ReturnToCallViewController.pipSize)
                    localMemberView.autoPinEdge(.bottom, to: .top, of: callControls, withOffset: -16)
                }

                localMemberView.autoPinEdge(toSuperviewEdge: .trailing, withInset: 16)
            } else {
                speakerPage.addSubview(localMemberView)
                localMemberView.autoPinEdgesToSuperviewEdges()
            }
        case .notJoined, .joining:
            speakerPage.addSubview(localMemberView)
            localMemberView.autoPinEdgesToSuperviewEdges()
        }

        updateScrollViewFrames()
    }

    func dismissCall() {
        callService.terminate(call: call)

        OWSWindowManager.shared.endCall(self)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
}

extension GroupCallViewController: CallViewControllerWindowReference {
    var localVideoViewReference: UIView {
        // TODO:
        localMemberView
    }

    var remoteVideoViewReference: UIView {
        // TODO:
        speakerView
    }

    var remoteVideoAddress: SignalServiceAddress {
        // TODO: get speaker
        guard let firstMember = groupCall.joinedGroupMembers.first else {
            return tsAccountManager.localAddress!
        }
        return SignalServiceAddress(uuid: firstMember)
    }

    func returnFromPip(pipWindow: UIWindow) {
        // TODO:
    }
}

extension GroupCallViewController: CallObserver {
    func groupCallLocalDeviceStateChanged(_ call: SignalCall) {
        AssertIsOnMainThread()
        owsAssertDebug(call.isGroupCall)

        updateCallUI()
    }

    func groupCallRemoteDeviceStatesChanged(_ call: SignalCall) {
        AssertIsOnMainThread()
        owsAssertDebug(call.isGroupCall)

    }

    func groupCallJoinedGroupMembersChanged(_ call: SignalCall) {
        AssertIsOnMainThread()
        owsAssertDebug(call.isGroupCall)

        updateCallUI()
    }

    func groupCallEnded(_ call: SignalCall, reason: GroupCallEndReason) {
        AssertIsOnMainThread()
        owsAssertDebug(call.isGroupCall)
    }

    func groupCallUpdateSfuInfo(_ call: SignalCall) {}
    func groupCallUpdateGroupMembershipProof(_ call: SignalCall) {}
    func groupCallUpdateGroupMembers(_ call: SignalCall) {}

    func individualCallStateDidChange(_ call: SignalCall, state: CallState) {}
    func individualCallLocalVideoMuteDidChange(_ call: SignalCall, isVideoMuted: Bool) {}
    func individualCallLocalAudioMuteDidChange(_ call: SignalCall, isAudioMuted: Bool) {}
    func individualCallRemoteVideoMuteDidChange(_ call: SignalCall, isVideoMuted: Bool) {}
    func individualCallHoldDidChange(_ call: SignalCall, isOnHold: Bool) {}
}

extension GroupCallViewController: CallControlsDelegate {
    func didPressHangup(sender: UIButton) {
        dismissCall()
    }

    func didPressAudioSource(sender: UIButton) {
        // TODO: Multiple Audio Sources
        sender.isSelected = !sender.isSelected
        callUIAdapter.audioService.requestSpeakerphone(isEnabled: sender.isSelected)
    }

    func didPressMute(sender: UIButton) {
        sender.isSelected = !sender.isSelected
        groupCall.isOutgoingAudioMuted = sender.isSelected
    }

    func didPressVideo(sender: UIButton) {
        sender.isSelected = !sender.isSelected
        callService.updateIsLocalVideoMuted(isLocalVideoMuted: !sender.isSelected)
    }

    func didPressFlipCamera(sender: UIButton) {
        sender.isSelected = !sender.isSelected
        callService.updateCameraSource(call: call, isUsingFrontCamera: !sender.isSelected)
    }

    func didPressCancel(sender: UIButton) {
        dismissCall()
    }

    func didPressJoin(sender: UIButton) {
        groupCall.join()
    }
}

extension GroupCallViewController: CallHeaderDelegate {
    func didTapBackButton() {
        if groupCall.localDevice.joinState == .joined {
            OWSWindowManager.shared.leaveCallView()
        } else {
            dismissCall()
        }
    }

    func didTapMembersButton() {

    }
}

extension GroupCallViewController: GroupCallVideoOverflowDelegate {
    var firstOverflowMemberIndex: Int {
        if scrollView.contentOffset.y >= view.height {
            return 1
        } else {
            return videoGrid.maxItems
        }
    }
}

extension GroupCallViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // If we changed pages, update the overflow view.
        if scrollView.contentOffset.y == 0 || scrollView.contentOffset.y == view.height {
            videoOverflow.reloadData()
        }
    }
}
