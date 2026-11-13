// The live waveform on the window's Now Playing page: a row of bars showing the
// last few seconds of Apple Music's sound, newest on the right, scrolling left.
// It samples and redraws many times a second, so it lives here in compiled code,
// and draws all its bars itself in one pass (no layout work), to keep CPU use low.
// Compiled at runtime by WatchdogWindow.ps1 via Add-Type, so it must stay within C# 5.
using System;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

public class Waveform : FrameworkElement {
    const double BarWidth = 4;
    const double Gap = 4;
    readonly double[] levels;
    readonly Brush[] fills;
    readonly Func<float> readLevel;
    readonly DispatcherTimer timer;
    double smoothed;

    // Whether Apple Music is playing; set by the window. When it isn't, the wave flattens.
    public bool Playing { get; set; }

    public Waveform(Brush fill, int count, Func<float> readLevel) {
        this.readLevel = readLevel;
        levels = new double[count];
        fills = new Brush[count];
        SetFill(fill);
        Width = count * (BarWidth + Gap) - Gap;
        timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(60) };
        timer.Tick += delegate { Step(); };
    }

    // The bars' colour, for when the window switches between light and dark.
    public void SetFill(Brush fill) {
        for (int i = 0; i < fills.Length; i++) {
            var brush = fill.CloneCurrentValue();
            brush.Opacity = 0.3 + 0.7 * i / (fills.Length - 1);   // older bars fade out
            brush.Freeze();
            fills[i] = brush;
        }
        InvalidateVisual();
    }

    public void Start() { timer.Start(); }
    public void Stop() { timer.Stop(); }

    void Step() {
        if (!IsVisible) return;   // other page, or hidden in the tray
        var window = Window.GetWindow(this);
        if (window != null && window.WindowState == WindowState.Minimized) return;
        double level = 0;
        if (Playing) {
            try { level = Math.Max(0, Math.Min(1, readLevel())); } catch { level = 0; }
        }
        // Rise quickly and fall gently, so it moves like a wave rather than flickering.
        smoothed = level > smoothed ? smoothed + (level - smoothed) * 0.55 : smoothed * 0.8 + level * 0.2;
        Array.Copy(levels, 1, levels, 0, levels.Length - 1);
        levels[levels.Length - 1] = smoothed;
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext drawing) {
        double height = ActualHeight;
        for (int i = 0; i < levels.Length; i++) {
            double h = Math.Max(BarWidth, height * levels[i]);   // silence is a row of dots
            drawing.DrawRoundedRectangle(fills[i], null, new Rect(i * (BarWidth + Gap), (height - h) / 2, BarWidth, h), BarWidth / 2, BarWidth / 2);
        }
    }
}
