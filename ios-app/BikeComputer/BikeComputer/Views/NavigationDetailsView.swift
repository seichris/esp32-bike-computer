//
//  NavigationDetailsView.swift
//  BikeComputer
//
//  Navigation instruction display view
//

import SwiftUI

struct NavigationDetailsView: View {
    let iconID: Int
    let distanceToManeuver: Int
    let instruction: String
    let isCompact: Bool
    
    init(iconID: Int, distanceToManeuver: Int, instruction: String, isCompact: Bool = false) {
        self.iconID = iconID
        self.distanceToManeuver = distanceToManeuver
        self.instruction = instruction
        self.isCompact = isCompact
    }
    
    var body: some View {
        VStack(spacing: isCompact ? 15 : 20) {
            // Arrow Icon
            Image(systemName: NavigationIcon.icon(for: iconID))
                .font(.system(size: isCompact ? 60 : 80))
                .foregroundColor(.blue)
            
            // Distance
            Text("\(distanceToManeuver)")
                .font(.system(size: isCompact ? 56 : 72, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            
            Text("meters")
                .font(isCompact ? .title3 : .title2)
                .foregroundColor(.secondary)
            
            // Instruction
            Text(instruction)
                .font(isCompact ? .title3 : .title2)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .lineLimit(isCompact ? 2 : nil)
        }
    }
}

struct MapNavigationInstructionCard: View {
    let iconID: Int
    let distanceToManeuver: Int
    let instruction: String
    let onStopNavigation: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 38, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 12)

            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 48, height: 48)

                    Image(systemName: NavigationIcon.icon(for: iconID))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(formattedDistance)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)

                    Text(instruction)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: onStopNavigation) {
                    Text("End")
                        .font(.headline)
                        .foregroundColor(.red)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End navigation")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
    }

    private var formattedDistance: String {
        if distanceToManeuver >= 1000 {
            return String(format: "%.1f km", Double(distanceToManeuver) / 1000)
        }

        return "\(distanceToManeuver) m"
    }
}

// MARK: - Navigation Icon Mapping

enum NavigationIcon {
    static func icon(for iconID: Int) -> String {
        switch iconID {
        case NavigationIconID.left: return "arrow.turn.up.left"
        case NavigationIconID.right: return "arrow.turn.up.right"
        case NavigationIconID.uTurn: return "arrow.uturn.left"
        case NavigationIconID.straight: return "arrow.up"
        default: return "arrow.up"
        }
    }
}
