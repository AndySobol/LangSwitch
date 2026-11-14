import Observation
import SwiftUI

/// A tiny particle engine for the trainer: sparks at the caret, bursts on combos, confetti on records.
///
/// It draws into one `Canvas` and its timeline is paused whenever no particle is alive, so an idle
/// trainer screen costs no frames.
@MainActor
@Observable
final class ParticleSystem {
    struct Particle {
        var position: CGPoint
        var velocity: CGVector
        var age: Double = 0
        var lifetime: Double
        var color: Color
        var size: CGFloat
        var rotation: Double
        var spin: Double
        var gravity: Double
        var isRectangle: Bool
    }

    @ObservationIgnored private(set) var particles: [Particle] = []
    @ObservationIgnored private var lastStep: Date?
    private(set) var isActive = false

    private func activate() {
        if !isActive {
            lastStep = nil
            isActive = true
        }
    }

    /// Sparks flying out from a point.
    func burst(
        at point: CGPoint, count: Int, colors: [Color], speed: ClosedRange<Double> = 60...220,
        size: ClosedRange<CGFloat> = 2...5
    ) {
        guard particles.count < 600 else { return }
        for _ in 0..<count {
            let angle = Double.random(in: 0..<(2 * .pi))
            let velocity = Double.random(in: speed)
            particles.append(
                Particle(
                    position: point,
                    velocity: CGVector(dx: cos(angle) * velocity, dy: sin(angle) * velocity - 60),
                    lifetime: Double.random(in: 0.35...0.8), color: colors.randomElement() ?? .white,
                    size: CGFloat.random(in: size), rotation: 0, spin: 0, gravity: 420, isRectangle: false))
        }
        activate()
    }

    /// Paper confetti raining over an area.
    func confetti(width: CGFloat, colors: [Color]) {
        for _ in 0..<140 {
            particles.append(
                Particle(
                    position: CGPoint(
                        x: CGFloat.random(in: 0...max(width, 1)), y: CGFloat.random(in: -80 ... -10)),
                    velocity: CGVector(dx: Double.random(in: -70...70), dy: Double.random(in: 60...240)),
                    lifetime: Double.random(in: 1.8...3.2), color: colors.randomElement() ?? .white,
                    size: CGFloat.random(in: 5...9), rotation: Double.random(in: 0...6),
                    spin: Double.random(in: -7...7),
                    gravity: 190, isRectangle: true))
        }
        activate()
    }

    /// Advances the simulation to `date`. Called from the canvas while it is drawing.
    func step(to date: Date) {
        let delta = min(date.timeIntervalSince(lastStep ?? date), 1.0 / 20)
        lastStep = date
        guard delta > 0 else { return }
        for index in particles.indices {
            particles[index].age += delta
            particles[index].velocity.dy += particles[index].gravity * delta
            particles[index].position.x += particles[index].velocity.dx * delta
            particles[index].position.y += particles[index].velocity.dy * delta
            particles[index].rotation += particles[index].spin * delta
        }
        particles.removeAll { $0.age >= $0.lifetime }
        if particles.isEmpty {
            // Publishing a change while the canvas is drawing is not allowed; do it right after.
            Task { @MainActor in
                if self.particles.isEmpty { self.isActive = false }
            }
        }
    }
}

struct ParticleField: View {
    let system: ParticleSystem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation(paused: !system.isActive)) { timeline in
                Canvas { context, _ in
                    system.step(to: timeline.date)
                    for particle in system.particles {
                        let fade = 1 - particle.age / particle.lifetime
                        var layer = context
                        layer.opacity = min(fade * 1.6, 1)
                        layer.translateBy(x: particle.position.x, y: particle.position.y)
                        if particle.isRectangle {
                            layer.rotate(by: .radians(particle.rotation))
                            // A rotating strip of paper: its apparent height follows the spin.
                            let height =
                                particle.size * CGFloat(0.35 + 0.65 * abs(cos(particle.rotation * 1.7)))
                            layer.fill(
                                Path(
                                    CGRect(
                                        x: -particle.size / 2, y: -height / 2, width: particle.size,
                                        height: height)),
                                with: .color(particle.color))
                        } else {
                            let size = particle.size * CGFloat(0.4 + 0.6 * fade)
                            layer.fill(
                                Path(
                                    ellipseIn: CGRect(x: -size / 2, y: -size / 2, width: size, height: size)),
                                with: .color(particle.color))
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}
