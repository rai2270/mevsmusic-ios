// Callbacks from the game logic to the platform UI layer (ported from
// mvm/game/GameEvents.java). Must stay free of UIKit/SceneKit/AVFoundation
// types: this is the seam the iOS shell implements.
protocol GameEvents: AnyObject {
    func showLoader()
    func hideLoader()
    func removeCountDown()
    func onShipUpdate(_ shipCount: Int)
    func onStatusUpdate(_ status: String, isCountDown: Bool)
    func gameOverData(title: String, score: Int)
    func gameOverStringTime()
    func gameOverTitleTime()
    func gameOverTop3Time()
    func gameOverTop31Time()
    func gameOverTop32Time()
    func gameOverTop33Time()
    func gameOverTime()
}
