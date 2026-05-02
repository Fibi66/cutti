import Foundation

func shouldDispatchShellSelection(currentSelection: UUID?, tappedID: UUID) -> Bool {
    currentSelection != tappedID
}
