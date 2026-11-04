#if CODE_COVERAGE_KIT_ENABLED && canImport(UIKit)
import UIKit

@MainActor
final class CoverageConsoleViewController: UIViewController {
    private let vViewModel = CoverageConsoleViewModel()
    private let vHeaderView = UIStackView()
    private let vBackButton = UIButton(type: .system)
    private var vScrollTopToSafeAreaConstraint: NSLayoutConstraint?
    private var vScrollTopToHeaderConstraint: NSLayoutConstraint?
    private let vScrollView = UIScrollView()
    private let vContentStackView = UIStackView()
    private let vServerURLTextField = UITextField()
    private let vServerURLSourceLabel = UILabel()
    private let vCredentialStatusLabel = UILabel()
    private let vSaveButton = UIButton(type: .system)
    private let vRestoreDefaultButton = UIButton(type: .system)
    private let vHealthButton = UIButton(type: .system)
    private let vUploadButton = UIButton(type: .system)
    private let vCoverageUploadButton = UIButton(type: .system)
    private let vOpenSettingsButton = UIButton(type: .system)
    private let vCoverageSummaryLabel = UILabel()
    private let vStatusTitleLabel = UILabel()
    private let vStatusDetailLabel = UILabel()

    /// 创建不依赖宿主基类、主题或业务资源的通用 Coverage 控制台。
    init() {
        super.init(nibName: nil, bundle: nil)
    }

    /// 禁止通过 storyboard 创建该纯代码控制台。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 建立原生 UIKit 表单、绑定主 Actor 状态，并显示已持久化配置。
    override func viewDidLoad() {
        super.viewDidLoad()
        p_setUpUI()
        p_bindViewModel()
        vServerURLTextField.text = vViewModel.serverURLText
        p_renderServerConfiguration(serverURLText: vViewModel.serverURLText, source: vViewModel.serverURLSource)
        p_render(state: vViewModel.state)
        vViewModel.refreshCoverageSummary()
    }

    /// 页面重新可见时适配宿主导航栏，并刷新后台快照或上次上传留下的磁盘计数。
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        p_updateNavigation()
        vViewModel.refreshCoverageSummary()
    }

    /// 页面退出导航栈时取消探针请求，避免无可见消费者的状态继续变化。
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true {
            vViewModel.cancelCurrentRequest()
        }
    }

    /// 配置导航 Header 和完整滚动约束链，以及配置、探针、上传、状态和权限说明区域。
    private func p_setUpUI() {
        title = "覆盖率网络验证"
        view.backgroundColor = .systemBackground
        p_setUpHeader()

        vScrollView.alwaysBounceVertical = true
        vScrollView.keyboardDismissMode = .interactive
        vScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vScrollView)
        vScrollTopToSafeAreaConstraint = vScrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        vScrollTopToHeaderConstraint = vScrollView.topAnchor.constraint(equalTo: vHeaderView.bottomAnchor)
        p_updateNavigation()

        vContentStackView.axis = .vertical
        vContentStackView.alignment = .fill
        vContentStackView.spacing = 12
        vContentStackView.translatesAutoresizingMaskIntoConstraints = false
        vScrollView.addSubview(vContentStackView)

        NSLayoutConstraint.activate([
            vScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            vScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            vContentStackView.topAnchor.constraint(equalTo: vScrollView.contentLayoutGuide.topAnchor, constant: 16),
            vContentStackView.leadingAnchor.constraint(equalTo: vScrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            vContentStackView.trailingAnchor.constraint(equalTo: vScrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            vContentStackView.bottomAnchor.constraint(equalTo: vScrollView.contentLayoutGuide.bottomAnchor, constant: -20),
            vContentStackView.widthAnchor.constraint(equalTo: vScrollView.frameLayoutGuide.widthAnchor, constant: -32)
        ])

        vContentStackView.addArrangedSubview(p_makeBodyLabel(
            text: "Coverage Debug 包会自动累计覆盖计数，启动和进入后台时只在本地生成 .profraw，不会联网。只有点击“上传覆盖数据”才会先刷新快照，再上传全部 pending。服务器地址可覆盖保存，上传凭证由当前测试包提供。",
            color: .secondaryLabel
        ))
        vContentStackView.addArrangedSubview(p_makeSectionTitleLabel(text: "当前 Coverage Build"))
        p_configureBodyLabel(vCoverageSummaryLabel, color: .secondaryLabel)
        vCoverageSummaryLabel.text = vViewModel.coverageSummaryText
        vContentStackView.addArrangedSubview(vCoverageSummaryLabel)

        p_styleButton(vCoverageUploadButton, title: "上传覆盖数据", primary: true, action: #selector(p_coverageUploadTapped))
        vCoverageUploadButton.isEnabled = false
        vCoverageUploadButton.alpha = 0.5
        vContentStackView.addArrangedSubview(vCoverageUploadButton)

        vContentStackView.addArrangedSubview(p_makeSectionTitleLabel(text: "Coverage 服务 URL"))
        p_styleTextField(vServerURLTextField, placeholder: "服务器地址")
        vServerURLTextField.keyboardType = .URL
        vServerURLTextField.textContentType = .URL
        vServerURLTextField.addTarget(self, action: #selector(p_inputDidChange), for: .editingChanged)
        vContentStackView.addArrangedSubview(vServerURLTextField)

        p_configureBodyLabel(vServerURLSourceLabel, color: .secondaryLabel)
        vContentStackView.addArrangedSubview(vServerURLSourceLabel)
        p_configureBodyLabel(vCredentialStatusLabel, color: .secondaryLabel)
        vCredentialStatusLabel.text = "受限上传凭证：已由当前测试包提供"
        vContentStackView.addArrangedSubview(vCredentialStatusLabel)

        p_styleButton(vSaveButton, title: "保存地址", primary: false, action: #selector(p_saveTapped))
        p_styleButton(vRestoreDefaultButton, title: "恢复包内默认地址", primary: false, action: #selector(p_restoreDefaultTapped))
        p_styleButton(vHealthButton, title: "检查 GET /health", primary: true, action: #selector(p_healthTapped))
        p_styleButton(vUploadButton, title: "上传无业务测试文件", primary: true, action: #selector(p_uploadTapped))
        [vSaveButton, vRestoreDefaultButton, vHealthButton, vUploadButton].forEach(vContentStackView.addArrangedSubview)

        let t_statusContainer = UIView()
        t_statusContainer.backgroundColor = .secondarySystemBackground
        t_statusContainer.layer.cornerRadius = 10
        vStatusTitleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        vStatusTitleLabel.textColor = .label
        p_configureBodyLabel(vStatusDetailLabel, color: .secondaryLabel)
        [vStatusTitleLabel, vStatusDetailLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            t_statusContainer.addSubview($0)
        }
        NSLayoutConstraint.activate([
            vStatusTitleLabel.topAnchor.constraint(equalTo: t_statusContainer.topAnchor, constant: 14),
            vStatusTitleLabel.leadingAnchor.constraint(equalTo: t_statusContainer.leadingAnchor, constant: 14),
            vStatusTitleLabel.trailingAnchor.constraint(equalTo: t_statusContainer.trailingAnchor, constant: -14),
            vStatusDetailLabel.topAnchor.constraint(equalTo: vStatusTitleLabel.bottomAnchor, constant: 8),
            vStatusDetailLabel.leadingAnchor.constraint(equalTo: t_statusContainer.leadingAnchor, constant: 14),
            vStatusDetailLabel.trailingAnchor.constraint(equalTo: t_statusContainer.trailingAnchor, constant: -14),
            vStatusDetailLabel.bottomAnchor.constraint(equalTo: t_statusContainer.bottomAnchor, constant: -14)
        ])
        vContentStackView.addArrangedSubview(t_statusContainer)

        vContentStackView.addArrangedSubview(p_makeBodyLabel(
            text: "权限与网络诊断：首次实际访问局域网时观察系统授权弹窗；若拒绝，请在系统设置中开启本地网络。连接失败时依次确认 Coverage 服务、当前 Wi-Fi、设备 VPN、AP/VLAN、App 重启和设备重启。App 不会通过 Bonjour 或其他方式绕过授权。",
            color: .tertiaryLabel
        ))
        p_styleButton(vOpenSettingsButton, title: "打开系统设置", primary: false, action: #selector(p_openSettingsTapped))
        vContentStackView.addArrangedSubview(vOpenSettingsButton)
    }

    /// 为隐藏系统导航栏的宿主构建原生 Header；标题自然换行，按钮保留 44 点触控区域。
    private func p_setUpHeader() {
        vBackButton.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
        vBackButton.tintColor = .label
        vBackButton.accessibilityLabel = "返回"
        vBackButton.addTarget(self, action: #selector(p_backTapped), for: .touchUpInside)

        let t_titleLabel = UILabel()
        t_titleLabel.text = title
        t_titleLabel.textColor = .label
        t_titleLabel.font = .preferredFont(forTextStyle: .headline)
        t_titleLabel.adjustsFontForContentSizeCategory = true
        t_titleLabel.numberOfLines = 0
        t_titleLabel.textAlignment = .center
        t_titleLabel.accessibilityTraits.insert(.header)

        let t_trailingSpace = UIView()
        vHeaderView.axis = .horizontal
        vHeaderView.alignment = .center
        vHeaderView.spacing = 8
        vHeaderView.translatesAutoresizingMaskIntoConstraints = false
        [vBackButton, t_titleLabel, t_trailingSpace].forEach(vHeaderView.addArrangedSubview)
        view.addSubview(vHeaderView)
        NSLayoutConstraint.activate([
            vHeaderView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            vHeaderView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            vHeaderView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            vBackButton.widthAnchor.constraint(equalToConstant: 44),
            vBackButton.heightAnchor.constraint(equalToConstant: 44),
            t_trailingSpace.widthAnchor.constraint(equalTo: vBackButton.widthAnchor)
        ])
    }

    /// 只选择系统导航或 SDK Header，不改动宿主导航栏；根页面不提供无效的返回操作。
    private func p_updateNavigation() {
        let t_navigation = navigationController
        let t_showsHeader = t_navigation.map { $0.isNavigationBarHidden || $0.navigationBar.isHidden } ?? true
        let t_canGoBack = t_navigation.map { $0.viewControllers.first !== self } ?? false
        vHeaderView.isHidden = !t_showsHeader
        // 保留左右对称占位，避免根页面隐藏返回操作后标题偏移。
        vBackButton.alpha = t_canGoBack ? 1 : 0
        vBackButton.isEnabled = t_canGoBack
        vBackButton.accessibilityElementsHidden = !t_canGoBack
        if t_showsHeader {
            vScrollTopToSafeAreaConstraint?.isActive = false
            vScrollTopToHeaderConstraint?.isActive = true
        } else {
            vScrollTopToHeaderConstraint?.isActive = false
            vScrollTopToSafeAreaConstraint?.isActive = true
        }
    }

    /// 返回当前宿主导航栈的上一页，沿用控制台退出时的请求取消流程。
    @objc private func p_backTapped() {
        navigationController?.popViewController(animated: true)
    }

    /// 绑定 ViewModel 完整状态快照，确保页面只渲染而不承载网络决策。
    private func p_bindViewModel() {
        vViewModel.onStateChange = { [weak self] state in self?.p_render(state: state) }
        vViewModel.onCoverageSummaryChange = { [weak self] text, canUpload in
            self?.p_renderCoverageSummary(text: text, canUpload: canUpload)
        }
        vViewModel.onServerConfigurationChange = { [weak self] serverURLText, source in
            self?.p_renderServerConfiguration(serverURLText: serverURLText, source: source)
        }
    }

    /// 根据状态类别更新文案颜色和操作可用性，不改变输入内容。
    private func p_render(state: CoverageConsoleViewModel.ViewState) {
        vStatusTitleLabel.text = state.title
        vStatusDetailLabel.text = state.detail
        switch state.kind {
        case .idle: vStatusTitleLabel.textColor = .label
        case .working: vStatusTitleLabel.textColor = .systemOrange
        case .success: vStatusTitleLabel.textColor = .systemGreen
        case .failure: vStatusTitleLabel.textColor = .systemRed
        }
        [vSaveButton, vRestoreDefaultButton, vHealthButton, vUploadButton].forEach {
            $0.isEnabled = !state.isBusy
            $0.alpha = state.isBusy ? 0.5 : 1
        }
        vCoverageUploadButton.isEnabled = !state.isBusy && vViewModel.canUploadCoverage
        vCoverageUploadButton.alpha = vCoverageUploadButton.isEnabled ? 1 : 0.5
        vServerURLTextField.isEnabled = !state.isBusy
    }

    /// 渲染当前服务地址及其来源，不展示或派生包内受限上传凭证的任何特征。
    private func p_renderServerConfiguration(serverURLText: String, source: CoverageConsoleViewModel.ServerURLSource) {
        vServerURLTextField.text = serverURLText
        vServerURLSourceLabel.text = "地址来源：\(source.rawValue)"
    }

    /// 更新只读 Cycle/Build 与队列计数，并与页面当前忙碌状态共同约束手动上传按钮。
    private func p_renderCoverageSummary(text: String, canUpload: Bool) {
        vCoverageSummaryLabel.text = text
        vCoverageUploadButton.isEnabled = canUpload && !vViewModel.state.isBusy
        vCoverageUploadButton.alpha = vCoverageUploadButton.isEnabled ? 1 : 0.5
    }

    /// 创建使用系统语义颜色和动态字体的自然多行段落标签。
    private func p_makeBodyLabel(text: String, color: UIColor) -> UILabel {
        let t_label = UILabel()
        t_label.text = text
        p_configureBodyLabel(t_label, color: color)
        return t_label
    }

    /// 配置可复用的系统正文样式和多行换行行为。
    private func p_configureBodyLabel(_ label: UILabel, color: UIColor) {
        label.textColor = color
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
    }

    /// 创建使用系统语义颜色和动态字体的表单区标题。
    private func p_makeSectionTitleLabel(text: String) -> UILabel {
        let t_label = UILabel()
        t_label.text = text
        t_label.textColor = .label
        t_label.font = .preferredFont(forTextStyle: .headline)
        t_label.adjustsFontForContentSizeCategory = true
        return t_label
    }

    /// 统一输入框的系统语义颜色、内边距、键盘行为和触控高度。
    private func p_styleTextField(_ textField: UITextField, placeholder: String) {
        textField.placeholder = placeholder
        textField.textColor = .label
        textField.font = .preferredFont(forTextStyle: .body)
        textField.backgroundColor = .secondarySystemBackground
        textField.layer.cornerRadius = 8
        textField.clearButtonMode = .whileEditing
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        textField.leftViewMode = .always
        textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    /// 统一操作按钮的系统语义颜色、圆角和触控高度，并连接页面事件。
    private func p_styleButton(_ button: UIButton, title: String, primary: Bool, action: Selector) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.setTitleColor(primary ? .white : .systemBlue, for: .normal)
        button.backgroundColor = primary ? .systemBlue : .secondarySystemBackground
        button.layer.cornerRadius = 8
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    /// 将当前文本输入同步给主 Actor ViewModel，但不在每次按键时写入持久化存储。
    @objc private func p_inputDidChange() { p_syncInputToViewModel() }

    /// 保存当前服务地址覆盖值，并关闭键盘以展示校验结果。
    @objc private func p_saveTapped() { p_endEditingAndSyncInput(); vViewModel.saveConfiguration() }

    /// 删除用户地址覆盖并立即刷新为当前安装包提供的默认地址。
    @objc private func p_restoreDefaultTapped() { view.endEditing(true); vViewModel.restoreBundleDefaultServerURL() }

    /// 主动请求无鉴权 `/health`，首次请求同时用于观察系统本地网络授权行为。
    @objc private func p_healthTapped() { p_endEditingAndSyncInput(); vViewModel.checkHealth() }

    /// 主动生成并上传无业务测试文件，以验证包内凭证、大小和 SHA-256 回显。
    @objc private func p_uploadTapped() { p_endEditingAndSyncInput(); vViewModel.uploadTestProbe() }

    /// 触发唯一 Coverage 网络动作；ViewModel/Collector 负责先快照、再上传和持久化。
    @objc private func p_coverageUploadTapped() { p_endEditingAndSyncInput(); vViewModel.uploadCoverageData() }

    /// 打开当前 App 的系统设置页，供用户在拒绝后恢复本地网络授权。
    @objc private func p_openSettingsTapped() {
        guard let t_url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(t_url) else { return }
        UIApplication.shared.open(t_url)
    }

    /// 将当前地址输入作为快照提交给 ViewModel，不接触包内上传凭证。
    private func p_syncInputToViewModel() {
        vViewModel.updateInput(serverURLText: vServerURLTextField.text ?? "")
    }

    /// 结束编辑并提交输入快照，保证按钮操作使用页面当前可见值。
    private func p_endEditingAndSyncInput() {
        view.endEditing(true)
        p_syncInputToViewModel()
    }
}
#endif
