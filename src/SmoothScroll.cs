// Smooth mouse-wheel scrolling for the window's pages. WPF on its own moves 16
// pixels per line in the Windows mouse setting (48 per notch with 3 lines, 32 with
// 2) and jumps there with no motion in between, which feels slow and jerky. This
// goes further per notch and glides there, and keeps gliding if the wheel keeps
// turning. A list inside the page (the font list) still scrolls by
// itself until it reaches its end; then the page carries on.
// Compiled at runtime by WatchdogWindow.ps1 via Add-Type, so it must stay within C# 5.
using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

public static class SmoothScroll {
    class Glide {
        public double Target;
        public double LastSet;
        public TimeSpan LastFrame;
        public bool Running;
    }

    static readonly Dictionary<ScrollViewer, Glide> glides = new Dictionary<ScrollViewer, Glide>();

    public static void Enable(ScrollViewer viewer) {
        glides[viewer] = new Glide();
        viewer.PreviewMouseWheel += OnWheel;
    }

    static void OnWheel(object sender, MouseWheelEventArgs e) {
        var page = (ScrollViewer)sender;
        // Over a list that can still scroll that way, the list scrolls; otherwise the page.
        var viewer = InnerList(e.OriginalSource as DependencyObject, page, e.Delta) ?? page;
        e.Handled = true;
        if (viewer.ScrollableHeight <= 0) return;

        Glide glide;
        if (!glides.TryGetValue(viewer, out glide)) {
            glide = new Glide();
            glides[viewer] = glide;
        }
        // 40 pixels per line in the Windows mouse setting (WPF uses 16), so 120 per notch
        // with the usual 3 lines.
        int lines = SystemParameters.WheelScrollLines > 0 ? SystemParameters.WheelScrollLines : 3;
        double step = -e.Delta / 120.0 * lines * 40;
        double from = glide.Running ? glide.Target : viewer.VerticalOffset;
        glide.Target = Math.Max(0, Math.Min(viewer.ScrollableHeight, from + step));
        if (!glide.Running) {
            glide.Running = true;
            glide.LastSet = viewer.VerticalOffset;
            glide.LastFrame = TimeSpan.Zero;
            EventHandler onFrame = null;
            onFrame = delegate(object s, EventArgs args) {
                if (!Step(viewer, glide, ((RenderingEventArgs)args).RenderingTime)) {
                    CompositionTarget.Rendering -= onFrame;
                    glide.Running = false;
                }
            };
            CompositionTarget.Rendering += onFrame;
        }
    }

    // Moves one frame's worth towards the target. False when it's done.
    static bool Step(ScrollViewer viewer, Glide glide, TimeSpan now) {
        // Something else moved the page (the scroll bar, the keyboard): stop gliding.
        if (Math.Abs(viewer.VerticalOffset - glide.LastSet) > 1) return false;
        double seconds = glide.LastFrame == TimeSpan.Zero ? 1 / 60.0 : (now - glide.LastFrame).TotalSeconds;
        if (seconds <= 0) return true;   // the same frame again
        glide.LastFrame = now;
        double remaining = glide.Target - viewer.VerticalOffset;
        if (Math.Abs(remaining) < 0.5) {
            viewer.ScrollToVerticalOffset(glide.Target);
            return false;
        }
        // Covers most of the remaining distance quickly, then eases in to a stop.
        double move = remaining * (1 - Math.Exp(-seconds / 0.075));
        glide.LastSet = viewer.VerticalOffset + move;
        viewer.ScrollToVerticalOffset(glide.LastSet);
        return true;
    }

    // The scrollable list inside the page under the mouse, if it can still scroll
    // the way the wheel turned. Null if there isn't one.
    static ScrollViewer InnerList(DependencyObject source, ScrollViewer page, int delta) {
        for (var node = source; node != null && node != page; node = Parent(node)) {
            var inner = node as ScrollViewer;
            if (inner == null || inner.ScrollableHeight <= 0) continue;
            if (delta > 0 ? inner.VerticalOffset > 0 : inner.VerticalOffset < inner.ScrollableHeight) return inner;
        }
        return null;
    }

    static DependencyObject Parent(DependencyObject node) {
        return node is Visual ? VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node);
    }
}
