import AppKit

// MARK: - Editar marcações já desenhadas: clicar, mover e mudar o tamanho

/// Alça de edição. `id` 0…7 são as do retângulo (a partir do canto de cima à esquerda, em sentido horário);
/// `Mark.startHandle` e `Mark.endHandle` são as pontas da linha e da seta.
struct MarkHandle {
    let id: Int
    let point: CGPoint
}

extension Mark {
    static let startHandle = 100
    static let endHandle = 101

    var textSize: CGSize {
        (text as NSString).size(withAttributes: [.font: Mark.font(for: width)])
    }

    /// Retângulo da marcação, sem contar a espessura do traço.
    var frame: CGRect {
        switch tool {
        case .text:
            guard let origin = points.first else { return .zero }
            return CGRect(origin: origin, size: textSize)
        case .pencil:
            return Mark.bounding(points)
        default:
            return box
        }
    }

    var handles: [MarkHandle] {
        switch tool {
        case .line, .arrow:
            guard let a = points.first, let b = points.last else { return [] }
            return [MarkHandle(id: Mark.startHandle, point: a), MarkHandle(id: Mark.endHandle, point: b)]
        case .text:
            // Só os cantos: o texto cresce ou diminui por igual.
            let all = Mark.boxHandles(frame)
            return [0, 2, 4, 6].map { MarkHandle(id: $0, point: all[$0]) }
        default:
            return Mark.boxHandles(frame).enumerated().map { MarkHandle(id: $0.offset, point: $0.element) }
        }
    }

    /// O clique caiu na marcação? Quadrado e círculo só contam perto do contorno, para dar para desenhar dentro deles.
    func contains(_ p: CGPoint) -> Bool {
        let tolerance = max(6, width / 2 + 4)
        switch tool {
        case .text, .blur:
            return frame.insetBy(dx: -4, dy: -4).contains(p)
        case .line, .arrow:
            guard let a = points.first, let b = points.last else { return false }
            return Mark.distance(p, a, b) <= tolerance
        case .pencil:
            guard let first = points.first else { return false }
            guard points.count > 1 else { return hypot(first.x - p.x, first.y - p.y) <= tolerance }
            return zip(points, points.dropFirst()).contains { Mark.distance(p, $0, $1) <= tolerance }
        case .rect:
            let inner = box.insetBy(dx: tolerance, dy: tolerance)
            let insideHole = inner.width > 0 && inner.height > 0 && inner.contains(p)
            return box.insetBy(dx: -tolerance, dy: -tolerance).contains(p) && !insideHole
        case .ellipse:
            let inner = box.insetBy(dx: tolerance, dy: tolerance)
            let insideHole = inner.width > 0 && inner.height > 0 && NSBezierPath(ovalIn: inner).contains(p)
            return NSBezierPath(ovalIn: box.insetBy(dx: -tolerance, dy: -tolerance)).contains(p) && !insideHole
        }
    }

    func moved(by dx: CGFloat, _ dy: CGFloat) -> Mark {
        var mark = self
        mark.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return mark
    }

    /// A marcação com a alça `handle` arrastada até `p`.
    func resized(handle: Int, to p: CGPoint) -> Mark {
        var mark = self
        switch tool {
        case .line, .arrow:
            if handle == Mark.startHandle { mark.points[0] = p } else { mark.points[mark.points.count - 1] = p }
        case .rect, .ellipse, .blur:
            let r = Mark.resize(box, handle: handle, to: p)
            mark.points = [r.origin, CGPoint(x: r.maxX, y: r.maxY)]
        case .pencil:
            let old = frame
            let r = Mark.resize(old, handle: handle, to: p)
            mark.points = points.map { q in
                CGPoint(x: old.width > 0.5 ? r.minX + (q.x - old.minX) * r.width / old.width : q.x + r.midX - old.midX,
                        y: old.height > 0.5 ? r.minY + (q.y - old.minY) * r.height / old.height : q.y + r.midY - old.midY)
            }
        case .text:
            // O canto oposto fica parado; a altura nova define o tamanho da letra.
            let old = frame
            guard old.height > 0 else { return mark }
            let anchorLeft = handle == 2 || handle == 4
            let anchorTop = handle == 4 || handle == 6
            let anchor = CGPoint(x: anchorLeft ? old.minX : old.maxX, y: anchorTop ? old.minY : old.maxY)
            let factor = max(abs(p.y - anchor.y), 6) / old.height
            let size = min(max(Mark.font(for: width).pointSize * factor, Mark.minFontSize), Mark.maxFontSize)
            mark.width = (size - 16) / 2
            let s = mark.textSize
            mark.points = [CGPoint(x: anchorLeft ? anchor.x : anchor.x - s.width, y: anchorTop ? anchor.y : anchor.y - s.height)]
        }
        return mark
    }

    // MARK: Geometria

    static func boxHandles(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    /// Retângulo com a alça `handle` (0…7) puxada até `p`; nunca menor que 4 pontos.
    static func resize(_ r: CGRect, handle: Int, to p: CGPoint) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case 0: minX = p.x; minY = p.y
        case 1: minY = p.y
        case 2: maxX = p.x; minY = p.y
        case 3: maxX = p.x
        case 4: maxX = p.x; maxY = p.y
        case 5: maxY = p.y
        case 6: minX = p.x; maxY = p.y
        default: minX = p.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: max(abs(maxX - minX), 4), height: max(abs(maxY - minY), 4))
    }

    static func bounding(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var r = CGRect(origin: first, size: .zero)
        for p in points.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    /// Distância de `p` ao segmento `a`–`b`.
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        guard length2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

// MARK: - Cursores

@MainActor
enum Cursors {
    /// Setas de redimensionar para a alça `handle` (0…7, origem em cima).
    static func resize(handle: Int) -> NSCursor {
        if #available(macOS 15.0, *) {
            let positions: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
            if positions.indices.contains(handle) { return .frameResize(position: positions[handle], directions: .all) }
        }
        switch handle {
        case 1, 5: return .resizeUpDown
        case 3, 7: return .resizeLeftRight
        default: return .crosshair
        }
    }
}
