// Decorative text for the Fluent window: a TextBlock that UI Automation hides (neither a control nor a content element), so glyphs and
// repeated labels are not read twice. Compiled at runtime with Add-Type after WPF is loaded; C# 5. Kept apart from WindowsFluentWindow.cs,
// which has no WPF references and is compiled without any.
using System.Windows.Automation.Peers;
using System.Windows.Controls;

namespace Bitworks.FastLlm {
    public class DecorativeTextBlock : TextBlock {
        protected override AutomationPeer OnCreateAutomationPeer() {
            return new DecorativePeer(this);
        }
    }

    public class DecorativePeer : FrameworkElementAutomationPeer {
        public DecorativePeer(TextBlock owner) : base(owner) {
        }

        protected override string GetClassNameCore() {
            return "DecorativeTextBlock";
        }

        protected override bool IsControlElementCore() {
            return false;
        }

        protected override bool IsContentElementCore() {
            return false;
        }
    }
}
