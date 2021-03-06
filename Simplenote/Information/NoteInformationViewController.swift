import UIKit
import SimplenoteFoundation

// MARK: - NoteInformationViewController
//
final class NoteInformationViewController: UIViewController {
    @IBOutlet private weak var tableView: UITableView!
    @IBOutlet private weak var screenTitleLabel: UILabel!
    @IBOutlet private weak var dismissButton: UIButton!
    @IBOutlet private weak var headerStackView: UIStackView!

    private var transitioningManager: UIViewControllerTransitioningDelegate?

    private var sections: [NoteInformationController.Section] = []
    private let controller: NoteInformationController

    /// Designated initializer
    ///
    /// - Parameters:
    ///     - controller: NoteInformationController
    ///
    init(controller: NoteInformationController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    /// Convenience initializer
    ///
    /// - Parameters:
    ///     - note: Note
    ///
    convenience init(note: Note) {
        self.init(controller: NoteInformationController(note: note))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopListeningToNotifications()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        configureViews()
        configureAccessibility()
        configureNavigation()

        refreshPreferredSize()

        startListeningToNotifications()
        startListeningForControllerChanges()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        configureHeaderLayoutMargins()
    }
}

// MARK: - Controller
//
private extension NoteInformationViewController {
    func startListeningForControllerChanges() {
        controller.observer = { [weak self] sections in
            self?.update(with: sections)
        }
    }

    func update(with sections: [NoteInformationController.Section]) {
        self.sections = sections
        tableView.reloadData()

        refreshPreferredSize()
    }
}

// MARK: - Configuration
//
private extension NoteInformationViewController {
    func configureNavigation() {
        title = Localization.information
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: Localization.done,
                                                            style: .done,
                                                            target: self,
                                                            action: #selector(handleTapOnDismissButton))
    }

    func configureViews() {
        configureTableView()
        screenTitleLabel.text = Localization.information

        removeHeaderViewIfNeeded()

        refreshStyle()
    }

    func configureTableView() {
        tableView.register(Value1TableViewCell.self, forCellReuseIdentifier: Value1TableViewCell.reuseIdentifier)
        tableView.register(SubtitleTableViewCell.self, forCellReuseIdentifier: SubtitleTableViewCell.reuseIdentifier)
        tableView.register(TableHeaderViewCell.self, forCellReuseIdentifier: TableHeaderViewCell.reuseIdentifier)
        tableView.tableFooterView = UIView()
    }

    func configureAccessibility() {
        dismissButton.accessibilityLabel = Localization.dismissAccessibilityLabel
    }

    func configureHeaderLayoutMargins() {
        headerStackView.isLayoutMarginsRelativeArrangement = true

        var layoutMargins = Consts.headerExtraLayoutMargins
        layoutMargins.left += tableView.layoutMargins.left
        layoutMargins.right += tableView.layoutMargins.right

        // Sync layout margins with table view so labels are aligned
        headerStackView.layoutMargins = layoutMargins
    }

    func removeHeaderViewIfNeeded() {
        guard navigationController != nil else {
            return
        }

        headerStackView.isHidden = true
    }

    func refreshPreferredSize() {
        preferredContentSize = tableView.intrinsicContentSize
    }
}

// MARK: - Styling
//
private extension NoteInformationViewController {
    func refreshStyle() {
        styleScreenTitleLabel()
        styleDismissButton()
        styleTableView()
    }

    func styleScreenTitleLabel() {
        screenTitleLabel.textColor = .simplenoteNoteHeadlineColor
    }

    func styleDismissButton() {
        dismissButton.layer.masksToBounds = true

        dismissButton.setImage(UIImage.image(name: .cross)?.withRenderingMode(.alwaysTemplate), for: .normal)

        dismissButton.setBackgroundImage(UIColor.simplenoteCardDismissButtonBackgroundColor.dynamicImageRepresentation(), for: .normal)
        dismissButton.setBackgroundImage(UIColor.simplenoteCardDismissButtonHighlightedBackgroundColor.dynamicImageRepresentation(), for: .highlighted)

        dismissButton.tintColor = .simplenoteCardDismissButtonTintColor
    }

    func styleTableView() {
        tableView.separatorColor = .simplenoteDividerColor
    }
}

// MARK: - Handling button events
//
private extension NoteInformationViewController {
    @IBAction func handleTapOnDismissButton() {
        dismiss(animated: true, completion: nil)
    }
}

// MARK: - UITableViewDelegate
//
extension NoteInformationViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        let row = sections[indexPath.section].rows[indexPath.row]
        switch row {
        case .reference(let interLink, _, _):
            if let interLink = interLink, let url = URL(string: interLink) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        default:
            break
        }
    }
}


// MARK: - UITableViewDataSource
//
extension NoteInformationViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]

        switch row {
        case .metric(let title, let value):
            let cell = tableView.dequeueReusableCell(ofType: Value1TableViewCell.self, for: indexPath)
            configure(cell: cell, withTitle: title, value: value)
            return cell
        case .reference(_, let title, let date):
            let cell = tableView.dequeueReusableCell(ofType: SubtitleTableViewCell.self, for: indexPath)
            configure(cell: cell, withTitle: title, date: date)
            return cell
        case .header(let title):
            let cell = tableView.dequeueReusableCell(ofType: TableHeaderViewCell.self, for: indexPath)
            configure(cell: cell, withTitle: title)
            return cell
        }
    }

    private func configure(cell: Value1TableViewCell, withTitle title: String, value: String?) {
        cell.selectionStyle = .none
        cell.hasClearBackground = true
        cell.title = title
        cell.detailTextLabel?.text = value
    }

    private func configure(cell: SubtitleTableViewCell, withTitle title: String, date: String) {
        cell.title = title
        cell.value = date
    }

    private func configure(cell: TableHeaderViewCell, withTitle title: String) {
        cell.title = title
    }

    private func updateSeparator(for cell: UITableViewCell, at indexPath: IndexPath) {
        if indexPath.row == sections[indexPath.section].rows.count - 1 {
            cell.adjustSeparatorWidth(width: .full)
        } else {
            cell.adjustSeparatorWidth(width: .standard)
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        updateSeparator(for: cell, at: indexPath)
    }
}

// MARK: - Notifications
//
private extension NoteInformationViewController {
    func startListeningToNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(themeDidChange), name: .SPSimplenoteThemeChanged, object: nil)
    }

    func stopListeningToNotifications() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func themeDidChange() {
        refreshStyle()
    }
}

// MARK: - Presentation
//
extension NoteInformationViewController {

    /// Configure view controller to be presented as a card
    ///
    func configureToPresentAsCard() {
        let transitioningManager = SPCardTransitioningManager()
        self.transitioningManager = transitioningManager

        transitioningDelegate = transitioningManager
        modalPresentationStyle = .custom
    }
}

private struct Localization {
    static let information = NSLocalizedString("Information", comment: "Card title showing information about the note (metrics, references)")
    static let done = NSLocalizedString("Done", comment: "Dismisses the Note Information UI")
    static let dismissAccessibilityLabel = NSLocalizedString("Dismiss Information", comment: "Accessibility label describing a button used to dismiss an information view of the note")
}

private struct Consts {
    static let headerExtraLayoutMargins = UIEdgeInsets(top: 16.0, left: 0.0, bottom: 0.0, right: 0.0)
}
