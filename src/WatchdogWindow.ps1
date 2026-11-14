# The watchdog's window, styled after the Apple Music app: a sidebar, a "now
# playing" display along the top, and two pages, Now Playing and Settings (which
# includes the timer). It follows the Windows light/dark setting and animates its
# controls and page changes. Closing it stops the watchdog, or, if you choose,
# hides it in the system tray while the watchdog keeps working.
#
# Dot-sourced by AppleMusicWatchdog.ps1, which provides $Settings, $State,
# $stopEvent, Invoke-WatchdogStep, Add-LogLine, Save-WatchdogSetting and the
# media-control helpers used here.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
Add-Type -Namespace AppleMusicWatchdog -Name Dwm -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
'@
[void][Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
Add-Type -Path (Join-Path $PSScriptRoot 'WindowsShell.cs')
. (Join-Path $PSScriptRoot 'Autostart.ps1')
Add-Type -Path (Join-Path $PSScriptRoot 'Waveform.cs') -ReferencedAssemblies PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -Path (Join-Path $PSScriptRoot 'SmoothScroll.cs') -ReferencedAssemblies PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$WindowTitle = 'Apple Music Watchdog'
# The window's identity on the taskbar ($AppId) comes from AppleMusicWatchdog.ps1 and
# is shared with its shortcuts.
$IconPath = Join-Path $env:LOCALAPPDATA 'AppleMusicWatchdog\watchdog.ico'
$ShortcutName = 'Apple Music Watchdog.lnk'

function Show-WatchdogError([string]$Message) {
    [void][System.Windows.MessageBox]::Show($Message, $WindowTitle, 'OK', 'Error')
}

# Asks the already-open window to come to the front, even from the tray.
function Show-OpenWatchdogWindow {
    try { [WindowsShell]::AllowOthersToTakeFocus() } catch { Write-Verbose 'Could not hand over focus.' }
    $showEvent = $null
    if ([System.Threading.EventWaitHandle]::TryOpenExisting('Local\AppleMusicWatchdogShow', [ref]$showEvent)) {
        [void]$showEvent.Set()
        $showEvent.Dispose()
    }
}

function Test-DarkTheme {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $light = (Get-ItemProperty $key -ErrorAction SilentlyContinue).AppsUseLightTheme
    $light -eq 0
}

# Whether the window should be dark: the Theme setting, or Windows' own setting.
function Test-UseDark {
    if ($Settings.Theme -eq 'Dark') { return $true }
    if ($Settings.Theme -eq 'Light') { return $false }
    Test-DarkTheme
}

# Colours sampled from the Apple Music app for Windows (dark), with a matching light set.
# Like Apple Music since its 2026 redesign: neutral greys, white text, and blue as the
# only accent. The album art supplies the rest of the colour.
$DarkColors = @{
    Background = '#1C1C1C'; Sidebar = '#201F21'; Card = '#282828'; Raised = '#323232'; Line = '#3A3A3A'
    Text = '#FFFFFF'; Secondary = '#A3A3A3'; Hover = '#2A2A2A'; Selected = '#303030'; Track = '#4A4A4A'
    Accent = '#0091FF'; Green = '#30D158'; Amber = '#FFB340'; Grey = '#8E8E8E'
    SwitchOff = '#9A9A9A'; Meter = '#FFFFFF'; Logo = '#FFFFFF'; LogoGlyph = '#000000'; LogoEdge = '#00000000'
    HeroShade = '#B81C1C1C'; ArtEmpty = '#323232'; Scroll = '#55FFFFFF'; HoverOverlay = '#18FFFFFF'
    Glass = '#1AFFFFFF'; GlassRaised = '#1AFFFFFF'
}
$LightColors = @{
    Background = '#F9F9F9'; Sidebar = '#F2F2F2'; Card = '#FFFFFF'; Raised = '#EDEDED'; Line = '#E3E3E3'
    Text = '#1A1A1A'; Secondary = '#616161'; Hover = '#EAEAEA'; Selected = '#E4E4E4'; Track = '#D4D4D4'
    Accent = '#0A7AFF'; Green = '#1F9E45'; Amber = '#C77700'; Grey = '#8E8E8E'
    SwitchOff = '#7A7A7A'; Meter = '#1A1A1A'; Logo = '#FFFFFF'; LogoGlyph = '#000000'; LogoEdge = '#D6D6D6'
    HeroShade = '#CCF9F9F9'; ArtEmpty = '#E8E8E8'; Scroll = '#44000000'; HoverOverlay = '#12000000'
    Glass = '#B3FFFFFF'; GlassRaised = '#12000000'
}

$WindowXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Apple Music Watchdog" Width="960" Height="720" MinWidth="860" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="{{Background}}" Foreground="{{Text}}"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <FontFamily x:Key="Display">Segoe UI Variable Display, Segoe UI</FontFamily>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{{Text}}"/>
    </Style>

    <Style x:Key="PageTitle" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{DynamicResource Display}"/>
      <Setter Property="FontSize" Value="34"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{{Text}}"/>
      <Setter Property="Margin" Value="0,0,0,20"/>
    </Style>

    <Style x:Key="SectionLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="17"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{{Text}}"/>
      <Setter Property="Margin" Value="2,0,0,10"/>
    </Style>

    <Style x:Key="RowTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Foreground" Value="{{Text}}"/>
    </Style>

    <Style x:Key="RowHint" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="{{Secondary}}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,3,0,0"/>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{{Card}}"/>
      <Setter Property="CornerRadius" Value="12"/>
    </Style>

    <!-- See-through cards for Now Playing, so the song's colours show through. -->
    <Style x:Key="GlassCard" TargetType="Border" BasedOn="{StaticResource Card}">
      <Setter Property="Background" Value="{{Glass}}"/>
    </Style>

    <Style x:Key="SettingCard" TargetType="Border" BasedOn="{StaticResource Card}">
      <Setter Property="Padding" Value="20,14"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
      <Setter Property="MinHeight" Value="72"/>
    </Style>


    <CubicEase x:Key="Ease" EasingMode="EaseOut"/>

    <!-- Sidebar item: hover and selection fade in, and the blue marker grows into place. -->
    <Style x:Key="NavItem" TargetType="RadioButton">
      <Setter Property="GroupName" Value="Nav"/>
      <Setter Property="Foreground" Value="{{Text}}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid Background="Transparent">
              <Border x:Name="Hover" CornerRadius="10" Background="{{Hover}}" Opacity="0"/>
              <Border x:Name="Picked" CornerRadius="10" Background="{{Selected}}" Opacity="0"/>
              <Border Padding="14,10">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" FontFamily="{StaticResource Icons}"
                             FontSize="18" Foreground="{{Text}}" VerticalAlignment="Center" Margin="0,0,16,0"/>
                  <ContentPresenter TextElement.FontSize="15" VerticalAlignment="Center"/>
                </StackPanel>
              </Border>
              <Border x:Name="Marker" Width="3" Height="18" CornerRadius="1.5" Background="{{Accent}}"
                      HorizontalAlignment="Left" Opacity="0" RenderTransformOrigin="0.5,0.5">
                <Border.RenderTransform><ScaleTransform ScaleY="0.2"/></Border.RenderTransform>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Hover" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.15" EasingFunction="{StaticResource Ease}"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Hover" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.25" EasingFunction="{StaticResource Ease}"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Picked" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.2" EasingFunction="{StaticResource Ease}"/>
                      <DoubleAnimation Storyboard.TargetName="Marker" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.15"/>
                      <DoubleAnimation Storyboard.TargetName="Marker" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                       To="1" Duration="0:0:0.3" EasingFunction="{StaticResource Ease}"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Picked" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.2" EasingFunction="{StaticResource Ease}"/>
                      <DoubleAnimation Storyboard.TargetName="Marker" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.15"/>
                      <DoubleAnimation Storyboard.TargetName="Marker" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                       To="0.2" Duration="0:0:0.2" EasingFunction="{StaticResource Ease}"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Switch in Apple Music's style. The dot slides across while the blue fades in,
         and the dot grows a little under the mouse. -->
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Foreground" Value="{{Text}}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <TextBlock x:Name="Label" Text="Off" FontSize="15" VerticalAlignment="Center" Margin="0,0,14,0"
                         Foreground="{TemplateBinding Foreground}"/>
              <Grid Width="44" Height="22">
                <Border CornerRadius="11" BorderThickness="1" BorderBrush="{{SwitchOff}}"/>
                <Border x:Name="OnFill" CornerRadius="11" Background="{{Accent}}" Opacity="0"/>
                <Grid x:Name="Knob" Width="12" Height="12" Margin="5,0,0,0" HorizontalAlignment="Left" RenderTransformOrigin="0.5,0.5">
                  <Grid.RenderTransform>
                    <TransformGroup>
                      <ScaleTransform/>
                      <TranslateTransform/>
                    </TransformGroup>
                  </Grid.RenderTransform>
                  <Ellipse Fill="{{SwitchOff}}"/>
                  <Ellipse x:Name="KnobOn" Fill="White" Opacity="0"/>
                </Grid>
              </Grid>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Label" Property="Text" Value="On"/>
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Knob" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[1].(TranslateTransform.X)"
                                       To="22" Duration="0:0:0.22" EasingFunction="{StaticResource Ease}"/>
                      <DoubleAnimation Storyboard.TargetName="OnFill" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.18"/>
                      <DoubleAnimation Storyboard.TargetName="KnobOn" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.18"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Knob" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[1].(TranslateTransform.X)"
                                       To="0" Duration="0:0:0.22" EasingFunction="{StaticResource Ease}"/>
                      <DoubleAnimation Storyboard.TargetName="OnFill" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.18"/>
                      <DoubleAnimation Storyboard.TargetName="KnobOn" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.18"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Knob" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleX)"
                                       To="1.2" Duration="0:0:0.15" EasingFunction="{StaticResource Ease}"/>
                      <DoubleAnimation Storyboard.TargetName="Knob" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleY)"
                                       To="1.2" Duration="0:0:0.15" EasingFunction="{StaticResource Ease}"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Knob" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleX)"
                                       To="1" Duration="0:0:0.2" EasingFunction="{StaticResource Ease}"/>
                      <DoubleAnimation Storyboard.TargetName="Knob" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleY)"
                                       To="1" Duration="0:0:0.2" EasingFunction="{StaticResource Ease}"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- The - and + buttons on steppers: the hover highlight fades, and they dip slightly when pressed. -->
    <Style x:Key="StepButton" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="{{Text}}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid x:Name="Root" Width="40" Height="36" Background="Transparent" RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><ScaleTransform/></Grid.RenderTransform>
              <Border x:Name="Hover" CornerRadius="8" Background="{{Selected}}" Opacity="0"/>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Hover" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.12"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Hover" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.2"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="0.9" Duration="0:0:0.08"/>
                      <DoubleAnimation Storyboard.TargetName="Root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="0.9" Duration="0:0:0.08"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.2" EasingFunction="{StaticResource Ease}"/>
                      <DoubleAnimation Storyboard.TargetName="Root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.2" EasingFunction="{StaticResource Ease}"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Root" Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Stepper" TargetType="Border">
      <Setter Property="Background" Value="{{Raised}}"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="2"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="StepValue" TargetType="TextBlock">
      <Setter Property="MinWidth" Value="76"/>
      <Setter Property="TextAlignment" Value="Center"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{{Text}}"/>
    </Style>

    <!-- Buttons: a soft highlight fades in under the mouse, and they dip slightly when pressed.
         Their colours are animated from code when they change (see Set-AnimatedBrush). -->
    <Style x:Key="Pill" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Background" Value="{{Raised}}"/>
      <Setter Property="Foreground" Value="{{Text}}"/>
      <Setter Property="Padding" Value="18,9"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid x:Name="Root" RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><ScaleTransform/></Grid.RenderTransform>
              <Border CornerRadius="19" Background="{TemplateBinding Background}"/>
              <Border x:Name="Hover" CornerRadius="19" Background="{{HoverOverlay}}" Opacity="0"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Hover" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.15"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Hover" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.25"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="0.96" Duration="0:0:0.08"/>
                      <DoubleAnimation Storyboard.TargetName="Root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="0.96" Duration="0:0:0.08"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.25" EasingFunction="{StaticResource Ease}"/>
                      <DoubleAnimation Storyboard.TargetName="Root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.25" EasingFunction="{StaticResource Ease}"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Root" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Chip" TargetType="Button" BasedOn="{StaticResource Pill}">
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Foreground" Value="{{Text}}"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border CornerRadius="4" Background="{{Scroll}}"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid x:Name="Shell" Opacity="0">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="232"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- Sidebar -->
    <Border Grid.Column="0" Background="{{Sidebar}}" BorderBrush="{{Line}}" BorderThickness="0,0,1,0">
      <DockPanel Margin="16,20,16,18">
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="6,0,0,26">
          <Border Width="40" Height="40" CornerRadius="12" Background="{{Logo}}" BorderBrush="{{LogoEdge}}" BorderThickness="1">
            <TextBlock Text="&#xE9D9;" FontFamily="{StaticResource Icons}" FontSize="20" Foreground="{{LogoGlyph}}"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="Watchdog" FontFamily="{DynamicResource Display}" FontSize="19" FontWeight="Bold"/>
            <TextBlock Text="for Apple Music" FontSize="12.5" Foreground="{{Secondary}}"/>
          </StackPanel>
        </StackPanel>
        <TextBlock x:Name="SidebarNote" DockPanel.Dock="Bottom" TextWrapping="Wrap"
                   FontSize="12.5" Foreground="{{Secondary}}" Margin="6,0"/>
        <StackPanel>
          <RadioButton x:Name="NavNow" Style="{StaticResource NavItem}" Tag="&#xE8D6;" Content="Now Playing" IsChecked="True"/>
          <RadioButton x:Name="NavSettings" Style="{StaticResource NavItem}" Tag="&#xE713;" Content="Settings"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- The content area. On Now Playing, it's filled with the song's colours. -->
    <Grid x:Name="Content" Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- Top bar: status, Apple Music's controls, the now-playing display, and the on/off button -->
      <Grid Grid.Row="0" Margin="28,16,28,8">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border Grid.Column="0" HorizontalAlignment="Left" VerticalAlignment="Center" CornerRadius="16"
                Background="{{Glass}}" Padding="14,7">
          <StackPanel Orientation="Horizontal">
            <Ellipse x:Name="PillDot" Width="9" Height="9" Fill="{{Green}}" VerticalAlignment="Center"/>
            <TextBlock x:Name="PillText" Text="Watching" FontSize="13.5" FontWeight="SemiBold" Margin="9,0,0,0"/>
          </StackPanel>
        </Border>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="12,0,0,0">
          <Button x:Name="PreviousButton" Style="{StaticResource StepButton}" FontSize="15" Content="&#xF8AC;" AutomationProperties.Name="Previous"/>
          <Button x:Name="PlayButton" Style="{StaticResource StepButton}" FontSize="19" Content="&#xF5B0;" AutomationProperties.Name="Play"/>
          <Button x:Name="NextButton" Style="{StaticResource StepButton}" FontSize="15" Content="&#xF8AD;" AutomationProperties.Name="Next"/>
        </StackPanel>
        <Border Grid.Column="2" MaxWidth="440" Height="56" CornerRadius="14" Background="{{Glass}}"
                BorderBrush="{{Line}}" BorderThickness="1" Margin="12,0,16,0">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="54"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border x:Name="ArtSmall" Grid.Column="0" CornerRadius="13,0,0,13" Background="{{ArtEmpty}}">
              <TextBlock x:Name="ArtSmallEmpty" Text="&#xE8D6;" FontFamily="{StaticResource Icons}" FontSize="20"
                         Foreground="{{Secondary}}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="14,0">
              <TextBlock x:Name="LcdTitle" FontSize="13.5" FontWeight="SemiBold" TextAlignment="Center" TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="LcdArtist" FontSize="12.5" Foreground="{{Secondary}}" TextAlignment="Center" TextTrimming="CharacterEllipsis"/>
              <Grid Margin="0,5,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="34"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="34"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="LcdElapsed" FontSize="10.5" Foreground="{{Secondary}}" VerticalAlignment="Center"/>
                <Grid Grid.Column="1" VerticalAlignment="Center" Margin="4,0">
                  <Border Height="3" CornerRadius="1.5" Background="{{Track}}"/>
                  <Border x:Name="LcdProgress" Height="3" CornerRadius="1.5" Background="{{Meter}}" RenderTransformOrigin="0,0.5">
                    <Border.RenderTransform><ScaleTransform ScaleX="0"/></Border.RenderTransform>
                  </Border>
                </Grid>
                <TextBlock x:Name="LcdRemaining" Grid.Column="2" FontSize="10.5" Foreground="{{Secondary}}" TextAlignment="Right" VerticalAlignment="Center"/>
              </Grid>
            </StackPanel>
          </Grid>
        </Border>
        <Button x:Name="ToggleWatch" Grid.Column="3" HorizontalAlignment="Right" VerticalAlignment="Center"
                Style="{StaticResource Pill}" Content="Stop Watching"/>
      </Grid>

      <Grid Grid.Row="1">
        <!-- Now Playing -->
        <ScrollViewer x:Name="PageNow" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="32,16,32,28">
            <TextBlock Style="{StaticResource PageTitle}" Text="Now Playing"/>
            <Border CornerRadius="16" MinHeight="262" Background="{{Glass}}">
              <Grid x:Name="Hero">
                <!-- The artwork, blurred (see New-BlurredArtwork) -->
                <Border x:Name="HeroBlur" Opacity="0.75"/>
                <Border Background="{{HeroShade}}"/>
                <Grid Margin="30">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="202"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Border x:Name="ArtBig" Width="202" Height="202" CornerRadius="10" Background="{{ArtEmpty}}" CacheMode="BitmapCache">
                    <Border.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="6" Opacity="0.45"/></Border.Effect>
                    <TextBlock x:Name="ArtBigEmpty" Text="&#xE8D6;" FontFamily="{StaticResource Icons}" FontSize="64"
                               Foreground="{{Secondary}}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <StackPanel Grid.Column="1" Margin="30,0,0,0" VerticalAlignment="Center">
                    <TextBlock x:Name="HeroState" FontSize="12.5" FontWeight="Bold" Foreground="{{Accent}}"/>
                    <TextBlock x:Name="HeroTitle" FontFamily="{DynamicResource Display}" FontSize="28" FontWeight="SemiBold"
                               TextTrimming="CharacterEllipsis" Margin="0,6,0,0"/>
                    <TextBlock x:Name="HeroArtist" FontSize="16" Foreground="{{Secondary}}" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                    <Grid Margin="0,24,0,0">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <Ellipse x:Name="HeroDot" Width="10" Height="10" Fill="{{Green}}" VerticalAlignment="Top" Margin="0,6,0,0"/>
                      <TextBlock x:Name="HeroWatch" Grid.Column="1" FontSize="15" Margin="10,0,0,0" TextWrapping="Wrap"/>
                    </Grid>
                    <Canvas x:Name="Wave" Margin="0,14,0,0" Width="340" Height="44" HorizontalAlignment="Left" ClipToBounds="True"/>
                    <TextBlock Text="Sound coming out of Apple Music" FontSize="12.5" Foreground="{{Secondary}}" Margin="0,7,0,0"/>
                  </StackPanel>
                </Grid>
              </Grid>
            </Border>
            <UniformGrid Columns="3" Margin="-6,16,-6,0">
              <Border Style="{StaticResource GlassCard}" Margin="6" Padding="20,16">
                <StackPanel>
                  <TextBlock Text="Fixes" FontSize="13" Foreground="{{Secondary}}"/>
                  <TextBlock x:Name="StatFixes" FontFamily="{DynamicResource Display}" FontSize="28" FontWeight="SemiBold" Margin="0,4,0,0"/>
                  <TextBlock x:Name="StatFixesNote" FontSize="12.5" Foreground="{{Secondary}}" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource GlassCard}" Margin="6" Padding="20,16">
                <StackPanel>
                  <TextBlock Text="Watching for" FontSize="13" Foreground="{{Secondary}}"/>
                  <TextBlock x:Name="StatUptime" FontFamily="{DynamicResource Display}" FontSize="28" FontWeight="SemiBold" Margin="0,4,0,0"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource GlassCard}" Margin="6" Padding="20,16">
                <StackPanel>
                  <TextBlock Text="Timer" FontSize="13" Foreground="{{Secondary}}"/>
                  <TextBlock x:Name="StatTimer" FontFamily="{DynamicResource Display}" FontSize="28" FontWeight="SemiBold" Margin="0,4,0,0"/>
                </StackPanel>
              </Border>
            </UniformGrid>
            <Border Style="{StaticResource GlassCard}" Margin="0,10,0,0" Padding="20,14">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Border Width="44" Height="44" CornerRadius="12" Background="{{GlassRaised}}">
                  <TextBlock Text="&#xE90F;" FontFamily="{StaticResource Icons}" FontSize="20"
                             HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <StackPanel Grid.Column="1" Margin="16,0" VerticalAlignment="Center">
                  <TextBlock x:Name="LastFixLabel" Text="Last fix" FontSize="13" Foreground="{{Secondary}}"/>
                  <TextBlock x:Name="LastFixText" FontFamily="{DynamicResource Display}" FontSize="18" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                </StackPanel>
                <Border x:Name="LastFixChip" Grid.Column="2" CornerRadius="14" Background="{{GlassRaised}}" Padding="12,5" VerticalAlignment="Center">
                  <TextBlock x:Name="LastFixResult" FontSize="13"/>
                </Border>
              </Grid>
            </Border>
            <Border Style="{StaticResource GlassCard}" Margin="0,10,0,0" Padding="20,14">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Border Width="44" Height="44" CornerRadius="12" Background="{{GlassRaised}}">
                  <TextBlock x:Name="RouteIcon" Text="&#xE7F5;" FontFamily="{StaticResource Icons}" FontSize="20"
                             HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <StackPanel Grid.Column="1" Margin="16,0" VerticalAlignment="Center">
                  <TextBlock x:Name="RouteLabel" Text="Playing through" FontSize="13" Foreground="{{Secondary}}"/>
                  <TextBlock x:Name="RouteName" FontFamily="{DynamicResource Display}" FontSize="18" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
                </StackPanel>
                <Border Grid.Column="2" CornerRadius="14" Background="{{GlassRaised}}" Padding="12,5" VerticalAlignment="Center">
                  <TextBlock x:Name="RouteKind" FontSize="13"/>
                </Border>
              </Grid>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- Settings: one card per setting, like Apple Music's settings -->
        <ScrollViewer x:Name="PageSettings" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel Margin="32,16,32,28">
            <TextBlock Style="{StaticResource PageTitle}" Text="Settings"/>
            <TextBlock Style="{StaticResource SectionLabel}" Text="When the sound stops"/>
            <Border Style="{StaticResource SettingCard}">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center" Margin="0,0,24,0">
                  <TextBlock Style="{StaticResource RowTitle}" Text="Pause and play after"/>
                  <TextBlock Style="{StaticResource RowHint}" Text="How long Apple Music can say it's playing with no sound before the watchdog steps in. A few seconds is longer than the gap between songs."/>
                </StackPanel>
                <Border Grid.Column="1" Style="{StaticResource Stepper}">
                  <StackPanel Orientation="Horizontal">
                    <Button x:Name="SilentDown" Style="{StaticResource StepButton}" Content="&#xE738;"/>
                    <TextBlock x:Name="SilentValue" Style="{StaticResource StepValue}"/>
                    <Button x:Name="SilentUp" Style="{StaticResource StepButton}" Content="&#xE710;"/>
                  </StackPanel>
                </Border>
              </Grid>
            </Border>
            <Border Style="{StaticResource SettingCard}">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center" Margin="0,0,24,0">
                  <TextBlock Style="{StaticResource RowTitle}" Text="Wait before trying again"/>
                  <TextBlock Style="{StaticResource RowHint}" Text="How long to wait if the sound doesn't come back, so a long outage doesn't keep pausing your music."/>
                </StackPanel>
                <Border Grid.Column="1" Style="{StaticResource Stepper}">
                  <StackPanel Orientation="Horizontal">
                    <Button x:Name="CooldownDown" Style="{StaticResource StepButton}" Content="&#xE738;"/>
                    <TextBlock x:Name="CooldownValue" Style="{StaticResource StepValue}"/>
                    <Button x:Name="CooldownUp" Style="{StaticResource StepButton}" Content="&#xE710;"/>
                  </StackPanel>
                </Border>
              </Grid>
            </Border>
            <Border Style="{StaticResource SettingCard}">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center" Margin="0,0,24,0">
                  <TextBlock Style="{StaticResource RowTitle}" Text="Restart Apple Music as a last resort"/>
                  <TextBlock Style="{StaticResource RowHint}" Text="If pausing and playing twice doesn't bring the sound back, the watchdog restarts the song, then skips to the next one. If that fails too, this closes Apple Music, opens it again and presses play, at most once every half hour."/>
                </StackPanel>
                <CheckBox x:Name="RestartAppleMusic" Grid.Column="1" Style="{StaticResource Switch}"/>
              </Grid>
            </Border>
            <Border Style="{StaticResource SettingCard}">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center" Margin="0,0,24,0">
                  <TextBlock Style="{StaticResource RowTitle}" Text="Stay paused when I pause"/>
                  <TextBlock Style="{StaticResource RowHint}" Text="The watchdog never presses play on music that's paused. When this is off, music that stopped while the internet was down starts again once it's back, even if you paused it yourself."/>
                </StackPanel>
                <CheckBox x:Name="RespectPause" Grid.Column="1" Style="{StaticResource Switch}"/>
              </Grid>
            </Border>
            <Border Style="{StaticResource SettingCard}">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center" Margin="0,0,24,0">
                  <TextBlock Style="{StaticResource RowTitle}" Text="Notifications"/>
                  <TextBlock Style="{StaticResource RowHint}" Text="A silent Windows notification when the internet drops out, when it took more than pausing and playing to get the sound back, or when nothing worked."/>
                </StackPanel>
                <CheckBox x:Name="Notify" Grid.Column="1" Style="{StaticResource Switch}"/>
              </Grid>
            </Border>
            <TextBlock Style="{StaticResource SectionLabel}" Text="Timer" Margin="2,22,0,10"/>
            <Border Style="{StaticResource SettingCard}">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center" Margin="0,0,24,0">
                  <TextBlock Style="{StaticResource RowTitle}" Text="Stop after a set time"/>
                  <TextBlock Style="{StaticResource RowHint}" Text="The watchdog stops watching when the time is up, so you can fall asleep to music."/>
                </StackPanel>
                <CheckBox x:Name="StopAfter" Grid.Column="1" Style="{StaticResource Switch}"/>
              </Grid>
            </Border>
            <Border x:Name="TimerOptions" Style="{StaticResource SettingCard}">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <StackPanel VerticalAlignment="Center" Margin="0,0,24,0">
                    <TextBlock Style="{StaticResource RowTitle}" Text="Duration"/>
                    <TextBlock Style="{StaticResource RowHint}" Text="Pick a time, or tap one below."/>
                  </StackPanel>
                  <Border Grid.Column="1" Style="{StaticResource Stepper}" Margin="0,0,10,0">
                    <StackPanel Orientation="Horizontal">
                      <Button x:Name="HoursDown" Style="{StaticResource StepButton}" Content="&#xE738;"/>
                      <TextBlock x:Name="HoursValue" Style="{StaticResource StepValue}"/>
                      <Button x:Name="HoursUp" Style="{StaticResource StepButton}" Content="&#xE710;"/>
                    </StackPanel>
                  </Border>
                  <Border Grid.Column="2" Style="{StaticResource Stepper}">
                    <StackPanel Orientation="Horizontal">
                      <Button x:Name="MinutesDown" Style="{StaticResource StepButton}" Content="&#xE738;"/>
                      <TextBlock x:Name="MinutesValue" Style="{StaticResource StepValue}"/>
                      <Button x:Name="MinutesUp" Style="{StaticResource StepButton}" Content="&#xE710;"/>
                    </StackPanel>
                  </Border>
                </Grid>
                <WrapPanel Margin="0,14,0,2">
                  <Button x:Name="Preset15" Style="{StaticResource Chip}" Content="15 min"/>
                  <Button x:Name="Preset30" Style="{StaticResource Chip}" Content="30 min"/>
                  <Button x:Name="Preset45" Style="{StaticResource Chip}" Content="45 min"/>
                  <Button x:Name="Preset60" Style="{StaticResource Chip}" Content="1 hr"/>
                  <Button x:Name="Preset120" Style="{StaticResource Chip}" Content="2 hr"/>
                  <Button x:Name="Preset240" Style="{StaticResource Chip}" Content="4 hr"/>
                </WrapPanel>
              </StackPanel>
            </Border>
            <Border x:Name="PauseRow" Style="{StaticResource SettingCard}">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center" Margin="0,0,24,0">
                  <TextBlock Style="{StaticResource RowTitle}" Text="Pause Apple Music when the time is up"/>
                  <TextBlock Style="{StaticResource RowHint}" Text="Otherwise the music keeps playing, just without the watchdog."/>
                </StackPanel>
                <CheckBox x:Name="PauseWhenDone" Grid.Column="1" Style="{StaticResource Switch}"/>
              </Grid>
            </Border>
            <Border x:Name="FadeRow" Style="{StaticResource SettingCard}">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center" Margin="0,0,24,0">
                  <TextBlock Style="{StaticResource RowTitle}" Text="Fade out first"/>
                  <TextBlock Style="{StaticResource RowHint}" Text="Turns Apple Music down slowly over the last 30 seconds before pausing it, then puts the volume back."/>
                </StackPanel>
                <CheckBox x:Name="FadeOut" Grid.Column="1" Style="{StaticResource Switch}"/>
              </Grid>
            </Border>
            <Border Style="{StaticResource SettingCard}">
              <StackPanel VerticalAlignment="Center">
                <TextBlock x:Name="TimerBig" FontFamily="{DynamicResource Display}" FontSize="26" FontWeight="SemiBold"/>
                <TextBlock x:Name="TimerSmall" Style="{StaticResource RowHint}"/>
              </StackPanel>
            </Border>
            <TextBlock Style="{StaticResource SectionLabel}" Text="Power" Margin="2,22,0,10"/>
            <Border Style="{StaticResource SettingCard}">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center" Margin="0,0,24,0">
                  <TextBlock Style="{StaticResource RowTitle}" Text="Keep the PC awake"/>
                  <TextBlock Style="{StaticResource RowHint}" Text="While music is playing. The screen can still turn off, and closing a laptop lid still puts it to sleep."/>
                </StackPanel>
                <CheckBox x:Name="KeepAwake" Grid.Column="1" Style="{StaticResource Switch}"/>
              </Grid>
            </Border>
            <TextBlock Style="{StaticResource SectionLabel}" Text="Appearance" Margin="2,22,0,10"/>
            <Border Style="{StaticResource SettingCard}">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center" Margin="0,0,24,0">
                  <TextBlock Style="{StaticResource RowTitle}" Text="Theme"/>
                  <TextBlock Style="{StaticResource RowHint}" Text="Light or dark, or the same as Windows."/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                  <Button x:Name="ThemeSystem" Style="{StaticResource Chip}" Content="System"/>
                  <Button x:Name="ThemeLight" Style="{StaticResource Chip}" Content="Light"/>
                  <Button x:Name="ThemeDark" Style="{StaticResource Chip}" Content="Dark" Margin="0"/>
                </StackPanel>
              </Grid>
            </Border>
            <TextBlock Style="{StaticResource SectionLabel}" Text="Window" Margin="2,22,0,10"/>
            <Border Style="{StaticResource SettingCard}">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center" Margin="0,0,24,0">
                  <TextBlock Style="{StaticResource RowTitle}" Text="Start when I sign in"/>
                  <TextBlock Style="{StaticResource RowHint}" Text="The watchdog starts watching in the background when you sign in to Windows, without opening this window. Opening the window takes over from it."/>
                </StackPanel>
                <CheckBox x:Name="StartAtSignIn" Grid.Column="1" Style="{StaticResource Switch}"/>
              </Grid>
            </Border>
            <Border Style="{StaticResource SettingCard}">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center" Margin="0,0,24,0">
                  <TextBlock Style="{StaticResource RowTitle}" Text="Keep running in the tray when closed"/>
                  <TextBlock Style="{StaticResource RowHint}" Text="Closing the window hides it in the system tray, off the taskbar, and the watchdog keeps working. Click the tray icon to open it again, or right-click it to quit."/>
                </StackPanel>
                <CheckBox x:Name="CloseToTray" Grid.Column="1" Style="{StaticResource Switch}"/>
              </Grid>
            </Border>
          </StackPanel>
        </ScrollViewer>


      </Grid>
    </Grid>
  </Grid>
</Window>
'@

function Show-WatchdogWindow {
    # Every colour is a shared brush in the window's resources (c_Background and so
    # on), so switching between light and dark can change them all at once.
    $xaml = $WindowXaml
    foreach ($key in $DarkColors.Keys) { $xaml = $xaml.Replace("{{$key}}", "{DynamicResource c_$key}") }
    $window = [Windows.Markup.XamlReader]::Parse($xaml)
    # Tall enough to show all of Now Playing, on screens that have the room.
    $window.Height = [Math]::Max($window.MinHeight, [Math]::Min(820.0, [System.Windows.SystemParameters]::WorkArea.Height - 40))

    $ui = @{ Deadline = $null; EndedAt = $null; ArtFor = $null; ActiveSince = Get-Date; OpenedAt = Get-Date; ThemeCheck = 0 }
    foreach ($match in [regex]::Matches($xaml, 'x:Name="(\w+)"')) {
        $name = $match.Groups[1].Value
        $ui[$name] = $window.FindName($name)
    }
    $colors = @{}   # the colours in use, by name, as #RRGGBB
    $brush = @{}    # the shared brushes, by name

    # Uses the light or dark colours. Every colour fades to its new value, unless
    # -Instant (when the window opens).
    function Set-Palette([bool]$Dark, [switch]$Instant) {
        $ui.Dark = $Dark
        $palette = if ($Dark) { $DarkColors } else { $LightColors }
        foreach ($key in $palette.Keys) {
            $colors[$key] = $palette[$key]
            $color = [System.Windows.Media.ColorConverter]::ConvertFromString($palette[$key])
            # A new brush each time: WPF locks a brush once its styles use it, so the old
            # one can't change. ::new, not New-Object: the resource dictionary rejects
            # PowerShell's wrapper.
            if ($Instant -or -not $brush[$key]) {
                $new = [System.Windows.Media.SolidColorBrush]::new($color)
            }
            else {
                # Fades from the old colour to the new one.
                $new = [System.Windows.Media.SolidColorBrush]::new($brush[$key].Color)
                $fade = New-Object System.Windows.Media.Animation.ColorAnimation
                $fade.To = $color
                $fade.Duration = [TimeSpan]::FromMilliseconds(350)
                $fade.EasingFunction = $ease
                $new.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $fade)
            }
            $brush[$key] = $new
            $window.Resources["c_$key"] = $new
        }
        if ($wave) { $wave.SetFill([System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($colors.Meter))) }
        Set-TitleBarColor
    }

    # Title bar in the same colours as the window (Windows 11; ignored elsewhere).
    function Set-TitleBarColor {
        $handle = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        if ($handle -eq [IntPtr]::Zero) { return }   # not shown yet
        $dark = [int]$ui.Dark
        [void][AppleMusicWatchdog.Dwm]::DwmSetWindowAttribute($handle, 20, [ref]$dark, 4)
        $color = [System.Windows.Media.ColorConverter]::ConvertFromString($colors.Background)
        $colorRef = [int]$color.R -bor ([int]$color.G -shl 8) -bor ([int]$color.B -shl 16)
        [void][AppleMusicWatchdog.Dwm]::DwmSetWindowAttribute($handle, 35, [ref]$colorRef, 4)
    }

    Set-Palette (Test-UseDark) -Instant

    # An error in a button or switch (say the settings file is locked for a moment)
    # shouldn't close the window and stop the watchdog: log it and carry on.
    $window.Dispatcher.Add_UnhandledException({
            Add-LogLine "Error: $($_.Exception.Message)"
            $_.Handled = $true
        })
    # The tray menu is a WinForms menu, whose errors go to WinForms instead. Unhandled,
    # WinForms shows its own error box, whose Quit button ends the watchdog without
    # cleaning up (pressing play again, putting the volume back). Log them instead.
    [System.Windows.Forms.Application]::add_ThreadException({ Add-LogLine "Error: $($args[1].Exception.Message)" })

    # Event handlers here are plain script blocks, not closures, so they can call
    # the functions defined in this function; they run while the window is open.
    $window.Add_SourceInitialized({ Set-TitleBarColor })

    # Our own taskbar identity, so the taskbar shows this icon rather than PowerShell's.
    try { [WindowsShell]::SetAppId($AppId) } catch { Write-Verbose "Couldn't set the taskbar identity: $($_.Exception.Message)" }
    $iconData = New-WatchdogIconData
    $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.IO.MemoryStream (, $iconData)))

    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = 'EaseOut'
    $ease.Freeze()
    $ui.Colors = @{}
    $ui.Opacities = @{}

    # Animates a number on an element (opacity, a transform, and so on).
    function Start-Animation($Target, [System.Windows.DependencyProperty]$Property, [double]$To, [int]$Milliseconds = 200, $From = $null) {
        $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
        $animation.To = $To
        if ($null -ne $From) { $animation.From = [double]$From }
        $animation.Duration = [TimeSpan]::FromMilliseconds($Milliseconds)
        $animation.EasingFunction = $ease
        $Target.BeginAnimation($Property, $animation)
    }

    # Fades an element's colour (Background, Foreground or Fill) to a new one. Called on
    # every refresh, so it only starts an animation when the colour actually changes.
    function Set-AnimatedBrush($Element, [string]$Property, [string]$Color) {
        $key = '{0}.{1}' -f $Element.GetHashCode(), $Property
        if ($ui.Colors[$key] -eq $Color) { return }
        $target = [System.Windows.Media.ColorConverter]::ConvertFromString($Color)
        $current = $Element.$Property
        if ($null -eq $ui.Colors[$key] -or -not ($current -is [System.Windows.Media.SolidColorBrush]) -or $current.IsFrozen) {
            # Give the element its own brush that can be animated.
            $start = if ($current -is [System.Windows.Media.SolidColorBrush]) { $current.Color } else { $target }
            $current = New-Object System.Windows.Media.SolidColorBrush $start
            $Element.$Property = $current
        }
        $ui.Colors[$key] = $Color
        $animation = New-Object System.Windows.Media.Animation.ColorAnimation
        $animation.To = $target
        $animation.Duration = [TimeSpan]::FromMilliseconds(250)
        $animation.EasingFunction = $ease
        $current.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $animation)
    }

    function Set-AnimatedOpacity($Element, [double]$Opacity) {
        $key = $Element.GetHashCode()
        if ($ui.Opacities[$key] -eq $Opacity) { return }
        $ui.Opacities[$key] = $Opacity
        Start-Animation $Element ([System.Windows.UIElement]::OpacityProperty) $Opacity 250
    }

    # Sets a text, fading it in when it changes if -Fade is given.
    function Set-Text($Control, [string]$Text, [switch]$Fade) {
        if ($Control.Text -eq $Text) { return }
        $Control.Text = $Text
        if ($Fade) { Start-Animation $Control ([System.Windows.UIElement]::OpacityProperty) 1 300 0.2 }
    }

    # Shows one page: it fades in and rises slightly into place.
    function Show-Page($Page) {
        foreach ($other in $pages.Values) {
            if ($other -ne $Page) { $other.Visibility = 'Collapsed' }
        }
        $Page.Visibility = 'Visible'
        Update-PageFill
        $shift = New-Object System.Windows.Media.TranslateTransform 0, 16
        $Page.RenderTransform = $shift
        Start-Animation $Page ([System.Windows.UIElement]::OpacityProperty) 1 260 0
        Start-Animation $shift ([System.Windows.Media.TranslateTransform]::YProperty) 0 340 16
    }

    # 1:05, or 1:02:03 for long tracks.
    function Format-SongTime([double]$Seconds) {
        $span = [TimeSpan]::FromSeconds([Math]::Floor($Seconds))
        if ($span.TotalHours -ge 1) { '{0}:{1:mm\:ss}' -f [int][Math]::Floor($span.TotalHours), $span } else { '{0}:{1:ss}' -f [int][Math]::Floor($span.TotalMinutes), $span }
    }

    # The live waveform (see Waveform.cs). It reads Apple Music's level through a .NET
    # delegate bound straight to a LevelReader (see AppAudio.cs), so it never runs
    # PowerShell code and can redraw smoothly without using much CPU.
    $levelReader = New-Object 'AppAudio+LevelReader' (, [string[]]$AudioProcesses)
    $readLevel = [Delegate]::CreateDelegate([Func[float]], $levelReader, 'Read')
    $wave = New-Object Waveform $brush.Meter, 42, $readLevel
    $wave.Height = $ui.Wave.Height
    [void]$ui.Wave.Children.Add($wave)

    # Which device Apple Music is playing through, checked every couple of seconds.
    $ui.RouteAt = [datetime]::MinValue
    function Update-Route {
        if ((Get-Date) -lt $ui.RouteAt) { return }
        $ui.RouteAt = (Get-Date).AddSeconds(2)
        $outputs = @(try { [AppAudio]::GetOutputs($AudioProcesses) } catch { @() })
        if (-not $outputs) {
            Set-Text $ui.RouteLabel 'Audio output'
            Set-Text $ui.RouteName 'No output device found'
            Set-Text $ui.RouteKind ''
            $ui.RouteIcon.Text = [string][char]0xE767
            return
        }
        $first = $outputs[0]
        Set-Text $ui.RouteLabel -Fade $(if ($first.InUse) { 'Playing through' } else { 'Will play through (default output)' })
        Set-Text $ui.RouteName -Fade (($outputs | ForEach-Object { $_.Name }) -join ' + ')
        $kind = if ($first.Connection -eq 'Built-in') { "This PC's $($first.Kind.ToLowerInvariant())" }
        elseif ($first.Connection -eq 'HDMI or DisplayPort') { 'Display (HDMI or DisplayPort)' }
        else { '{0} {1}' -f $first.Connection, $first.Kind.ToLowerInvariant() }
        Set-Text $ui.RouteKind $kind
        $ui.RouteIcon.Text = switch ($first.Kind) {
            'Headphones' { [string][char]0xE7F6 }
            'Headset' { [string][char]0xE7F6 }
            'Display' { [string][char]0xE7F4 }
            'Speakers' { [string][char]0xE7F5 }
            default { [string][char]0xE767 }
        }
    }

    # Moves the song progress bar to a new position, gliding at a steady speed until
    # the next update so it looks like continuous motion.
    function Set-Meter($Bar, [double]$Level) {
        $key = 'meter{0}' -f $Bar.GetHashCode()
        if ($null -ne $ui.Opacities[$key] -and [Math]::Abs($ui.Opacities[$key] - $Level) -lt 0.001) { return }
        $jump = $null -eq $ui.Opacities[$key] -or [Math]::Abs($ui.Opacities[$key] - $Level) -gt 0.05   # new song or a seek
        $ui.Opacities[$key] = $Level
        $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
        $animation.To = $Level
        $animation.Duration = [TimeSpan]::FromMilliseconds($(if ($jump) { 300 } else { 520 }))
        if ($jump) { $animation.EasingFunction = $ease }
        $Bar.RenderTransform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $animation)
    }

    function Format-Span([TimeSpan]$Span) {
        '{0}:{1:mm\:ss}' -f [int][Math]::Floor($Span.TotalHours), $Span
    }

    function Format-SecondCount([int]$Seconds) {
        if ($Seconds -lt 60) { return "$Seconds sec" }
        $minutes = [Math]::Floor($Seconds / 60)
        $rest = $Seconds % 60
        if ($rest) { "$minutes min $rest sec" } else { "$minutes min" }
    }

    function Format-Duration([int]$Minutes) {
        $hours = [Math]::Floor($Minutes / 60)
        $rest = $Minutes % 60
        if (-not $hours) { "$rest min" } elseif (-not $rest) { "$hours hr" } else { "$hours hr $rest min" }
    }

    # The next value a stepper moves to. Steps get bigger as the value grows, so
    # long times don't take dozens of clicks.
    function Get-StepValue([int]$Value, [int]$Minimum, [int]$Maximum, [bool]$Up, [int[][]]$Steps) {
        $probe = if ($Up) { $Value } else { $Value - 1 }
        $step = ($Steps | Where-Object { $probe -lt $_[0] } | Select-Object -First 1)[1]
        if (-not $step) { $step = $Steps[-1][1] }
        $next = if ($Up) { [Math]::Floor($Value / $step) * $step + $step } else { [Math]::Ceiling($Value / $step) * $step - $step }
        [int][Math]::Min($Maximum, [Math]::Max($Minimum, $next))
    }

    $silentSteps = [int[][]]@(@(30, 1), @(120, 5), @(601, 30))
    $cooldownSteps = [int[][]]@(@(60, 5), @(600, 30), @(3601, 60))

    function Get-TimerLength { [Math]::Max(1, $Settings.StopAfterHours * 60 + $Settings.StopAfterMinutes) }

    # Starts the time limit from now, if one is set.
    function Reset-Deadline {
        Stop-Fade
        $ui.EndedAt = $null
        $ui.Deadline = if ($State.Active -and $Settings.StopAfterEnabled) { (Get-Date).AddMinutes((Get-TimerLength)) } else { $null }
    }

    function Set-TimerLength([int]$Minutes) {
        $Minutes = [Math]::Min(23 * 60 + 55, [Math]::Max(5, $Minutes))
        $Settings.StopAfterHours = [int][Math]::Floor($Minutes / 60)
        $Settings.StopAfterMinutes = $Minutes % 60
        Save-WatchdogSetting
        Reset-Deadline
        Update-Display
    }

    # Fading out at the end of the timer: Apple Music's volume (in the Windows volume
    # mixer) goes down over the last 30 seconds, and is put back after it's paused.
    $FadeSeconds = 30
    $fadeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $fadeTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $fadeTimer.Add_Tick({
            try {
                if (-not $ui.Deadline) { Stop-Fade; return }
                $span = ($ui.Deadline - $ui.FadeStart).TotalSeconds
                $done = if ($span -gt 0) { [Math]::Min(1.0, ((Get-Date) - $ui.FadeStart).TotalSeconds / $span) } else { 1.0 }
                # Squared, so it sounds like an even fade rather than a sudden drop at the end.
                [void][AppAudio]::SetVolume($AudioProcesses, [float]($State.FadeFrom * (1 - $done) * (1 - $done)))
            }
            catch {
                Add-LogLine "Error while fading out: $($_.Exception.Message)"
                Stop-Fade
            }
        })

    function Start-Fade {
        $volume = [AppAudio]::GetVolume($AudioProcesses)
        if ($volume -le 0) { return }
        $State.FadeFrom = $volume
        $ui.FadeStart = Get-Date
        # Saved, so the volume can still be put back if the PC shuts down mid-fade.
        $Settings.RestoreVolume = $volume
        Save-WatchdogSetting
        $fadeTimer.Start()
        Add-LogLine 'Fading out'
    }

    # Ends a fade and puts the volume back.
    function Stop-Fade {
        $fadeTimer.Stop()
        $ui.RestoreAt = $null
        if ($State.FadeFrom -lt 0) { return }
        $restored = [AppAudio]::SetVolume($AudioProcesses, $State.FadeFrom) -gt 0
        $State.FadeFrom = -1.0
        # If Apple Music isn't open, the saved volume stays, and the watchdog puts it
        # back once it is (see Invoke-WatchdogStep).
        if ($restored) {
            $Settings.RestoreVolume = -1.0
            Save-WatchdogSetting
        }
    }

    function Start-Watching {
        $State.Active = $true
        $ui.ActiveSince = Get-Date
        Reset-Deadline
        Add-LogLine 'Started watching'
    }

    function Stop-Watching([string]$Reason) {
        # Puts the volume back straight away, unless the timer is about to (Stop-Session).
        if (-not $ui.RestoreAt) { Stop-Fade }
        $State.Active = $false
        $State.SilentSince = $null
        # A connection check or a wait for the internet is for a fix that won't happen now.
        if ($State.Phase -in 'Checking', 'Offline') {
            Stop-ConnectionCheck
            $State.Phase = 'Watching'
        }
        $ui.Deadline = $null
        [AppAudio]::SetKeepAwake($false)
        Add-LogLine $Reason
    }

    function Stop-Session {
        $fixed = switch ($State.Fixes) { 0 { 'no fixes needed' } 1 { 'fixed once' } default { "fixed $_ times" } }
        if ($State.FadeFrom -ge 0) {
            # Faded out: put the volume back a moment after pausing, once it's quiet.
            $fadeTimer.Stop()
            $ui.RestoreAt = (Get-Date).AddSeconds(1.5)
            $ui.PauseRetried = $false
        }
        Stop-Watching "Time is up. Stopped watching ($fixed)"
        $ui.EndedAt = Get-Date
        if ($Settings.PauseWhenDone) {
            # Don't let a fix that's under way press play again afterwards.
            $State.Phase = 'Watching'
            $State.FixKind = ''
            $State.FixSession = $null
            Stop-ConnectionCheck
            $session = Get-AppleMusicSession $State.Manager
            # Anything but already paused or stopped (it may be between songs, say).
            if ($session -and $session.GetPlaybackInfo().PlaybackStatus -notin 'Paused', 'Stopped', 'Closed') {
                [void](Wait-AsyncOperation ($session.TryPauseAsync()) ([bool]))
                Add-LogLine 'Paused Apple Music'
            }
        }
    }

    # The previous, play/pause and next buttons (in the top bar and the tray menu)
    # control Apple Music directly.
    function Invoke-MediaButton([string]$Action) {
        $session = Get-AppleMusicSession $State.Manager
        if (-not $session) { return }
        # You're taking over, so a fix under way stops here.
        if ($State.Phase -in 'Checking', 'Offline', 'Paused', 'Resumed') {
            Stop-ConnectionCheck
            $State.Phase = 'Watching'
            $State.FixKind = ''
            $State.FixSession = $null
        }
        $State.SilentSince = $null
        $operation = switch ($Action) {
            'Previous' { $session.TrySkipPreviousAsync() }
            'Next' { $session.TrySkipNextAsync() }
            default { if ($session.GetPlaybackInfo().PlaybackStatus -eq 'Playing') { $session.TryPauseAsync() } else { $session.TryPlayAsync() } }
        }
        [void](Wait-AsyncOperation $operation ([bool]))
        $State.TitleAt = [datetime]::MinValue   # read the song again straight away
        Invoke-WatchdogStep
        Update-Display
    }

    # Like Apple Music, Now Playing is filled with the song's colours: a gradient from
    # the artwork's main colour at the top to its second colour at the bottom, darker
    # or lighter to suit the theme. Other pages, and songs without artwork, use the
    # plain background. The colours fade when they change.
    $pageFill = New-Object System.Windows.Media.LinearGradientBrush
    $pageFill.StartPoint = New-Object System.Windows.Point 0, 0
    $pageFill.EndPoint = New-Object System.Windows.Point 0.35, 1
    foreach ($offset in 0, 1) {
        $pageFill.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString($colors.Background)), $offset))
    }
    $ui.Content.Background = $pageFill
    $ui.ArtColors = $null

    function Update-PageFill {
        $plain = [System.Windows.Media.ColorConverter]::ConvertFromString($colors.Background)
        $targets = if ($ui.ArtColors -and $ui.PageNow.Visibility -eq 'Visible') {
            ConvertTo-PageColor $ui.ArtColors[0] $ui.Dark
            ConvertTo-PageColor $ui.ArtColors[1] $ui.Dark
        }
        else { $plain, $plain }
        for ($i = 0; $i -lt 2; $i++) {
            $fade = New-Object System.Windows.Media.Animation.ColorAnimation
            $fade.To = $targets[$i]
            $fade.Duration = [TimeSpan]::FromMilliseconds(700)
            $fade.EasingFunction = $ease
            $pageFill.GradientStops[$i].BeginAnimation([System.Windows.Media.GradientStop]::ColorProperty, $fade)
        }
    }

    # Shows the current song's artwork, or a music note when there is none.
    function Update-Artwork {
        # Includes whether there's artwork yet: Apple Music sometimes sends it a moment
        # after the title, and it should still show up when it does.
        $key = '{0}|{1}|{2}' -f $State.Title, $State.Artist, [bool]$State.Artwork
        if ($key -eq $ui.ArtFor) { return }
        $ui.ArtFor = $key
        $image = $null
        if ($State.Artwork) {
            try { $image = Read-Artwork $State.Artwork }
            catch { Write-Verbose "Couldn't load the artwork: $($_.Exception.Message)" }
        }
        if ($image) {
            foreach ($target in $ui.ArtSmall, $ui.ArtBig) {
                $fill = New-Object System.Windows.Media.ImageBrush $image
                $fill.Stretch = 'UniformToFill'
                $target.Background = $fill
            }
            $blurred = New-Object System.Windows.Media.ImageBrush (New-BlurredArtwork $image)
            $blurred.Stretch = 'UniformToFill'
            $ui.HeroBlur.Background = $blurred
            $ui.ArtSmallEmpty.Visibility = 'Collapsed'
            $ui.ArtBigEmpty.Visibility = 'Collapsed'
            $ui.ArtColors = try { Get-ArtworkPalette $image } catch { $null }
        }
        else {
            # By name, so it follows the theme when that changes.
            $ui.ArtSmall.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'c_ArtEmpty')
            $ui.ArtBig.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'c_ArtEmpty')
            $ui.HeroBlur.Background = $null
            $ui.ArtSmallEmpty.Visibility = 'Visible'
            $ui.ArtBigEmpty.Visibility = 'Visible'
            $ui.ArtColors = $null
        }
        Update-PageFill
        foreach ($target in $ui.ArtSmall, $ui.ArtBig, $ui.HeroTitle, $ui.HeroArtist, $ui.LcdTitle, $ui.LcdArtist) {
            Start-Animation $target ([System.Windows.UIElement]::OpacityProperty) 1 400 0
        }
        Start-Animation $ui.HeroBlur ([System.Windows.UIElement]::OpacityProperty) 0.75 700 0
    }

    # What each kind of fix did, for the "Last fix" card.
    $fixNames = @{
        PausePlay   = 'Paused and played'
        RestartSong = 'Restarted the song'
        NextSong    = 'Skipped to the next song'
        RestartApp  = 'Restarted Apple Music'
        Play        = 'Pressed play'
    }

    # "just now", "5 min ago", "2 hr ago"
    function Format-Ago([datetime]$Time) {
        $minutes = [int][Math]::Floor(((Get-Date) - $Time).TotalMinutes)
        if ($minutes -lt 1) { 'just now' } elseif ($minutes -lt 60) { "$minutes min ago" } else { '{0} hr ago' -f [int][Math]::Floor($minutes / 60) }
    }

    function Update-Display {
        $now = Get-Date
        Update-Artwork

        # Song
        $hasSong = [bool]$State.Title
        $title = if ($hasSong) { $State.Title } elseif ($State.Status -eq 'Not running') { 'Apple Music isn''t open' } else { 'Nothing playing' }
        Set-Text $ui.LcdTitle $title
        Set-Text $ui.LcdArtist $State.Artist
        Set-Text $ui.HeroTitle $title
        Set-Text $ui.HeroArtist $(if ($hasSong) { $State.Artist } else { 'Play something in Apple Music' })
        Set-Text $ui.HeroState $State.Status.ToUpperInvariant() -Fade
        # How far into the song: Apple Music's last report, moved on by the time since.
        if ($State.Duration -gt 0) {
            $position = $State.Position
            if ($State.Status -eq 'Playing') { $position += ($now - $State.PositionAt).TotalSeconds }
            # 0.0, not 0: with a whole number, PowerShell picks the whole-number Max and rounds.
            $position = [Math]::Min($State.Duration, [Math]::Max(0.0, $position))
            Set-Meter $ui.LcdProgress ($position / $State.Duration)
            Set-Text $ui.LcdElapsed (Format-SongTime $position)
            Set-Text $ui.LcdRemaining ('-' + (Format-SongTime ($State.Duration - $position)))
        }
        else {
            Set-Meter $ui.LcdProgress 0
            Set-Text $ui.LcdElapsed ''
            Set-Text $ui.LcdRemaining ''
        }
        Update-Route
        $wave.Playing = $State.Status -eq 'Playing'
        $hasApp = $State.Status -ne 'Not running'
        foreach ($button in $ui.PreviousButton, $ui.PlayButton, $ui.NextButton) { $button.IsEnabled = $hasApp }
        $playing = $State.Status -eq 'Playing'
        $ui.PlayButton.Content = [string][char]$(if ($playing) { 0xF8AE } else { 0xF5B0 })
        [System.Windows.Automation.AutomationProperties]::SetName($ui.PlayButton, $(if ($playing) { 'Pause' } else { 'Play' }))

        # What the watchdog is doing
        $dot = $colors.Green
        $watch = if (-not $State.Active) {
            $dot = $colors.Grey
            if ($ui.EndedAt) { 'Not watching. The timer ran out.' } else { 'Not watching. Press Start Watching when you''re ready.' }
        }
        elseif ($State.FadeFrom -ge 0) {
            'Time''s nearly up. Fading the music out...'
        }
        elseif ($State.Phase -eq 'Offline') {
            $dot = $colors.Amber
            'No sound, and Apple Music can''t be reached. Waiting for the internet to come back, then the watchdog will fix it.'
        }
        elseif ($State.Phase -eq 'Checking') {
            $dot = $colors.Amber
            if ($State.SilentSince) { 'No sound for {0} sec. Checking the internet connection...' -f [int]($now - $State.SilentSince).TotalSeconds }
            else { 'No sound. Checking the internet connection...' }
        }
        elseif ($State.Phase -ne 'Watching') {
            $dot = $colors.Accent
            switch ($State.FixKind) {
                'RestartSong' { 'Still no sound. Restarting the song...' }
                'NextSong' { 'Still no sound. Skipping to the next song...' }
                'RestartApp' { 'Still no sound. Restarting Apple Music...' }
                default { if ($State.FailedFixes) { 'Still no sound. Pausing and playing again...' } else { 'No sound came through. Pausing and playing again...' } }
            }
        }
        elseif ($State.SilentSince) {
            $dot = $colors.Amber
            $silentFor = [int]($now - $State.SilentSince).TotalSeconds
            if ($now -lt $State.CooldownUntil) {
                'No sound for {0} sec. Trying again in {1} sec.' -f $silentFor, [int][Math]::Ceiling(($State.CooldownUntil - $now).TotalSeconds)
            }
            else {
                'No sound for {0} sec. Pausing and playing at {1} sec.' -f $silentFor, $Settings.SilentSeconds
            }
        }
        elseif ($State.Status -eq 'Playing') {
            'Sound is coming through.'
        }
        elseif ($State.PausedByYou -and $Settings.RespectPause) {
            'Watching. You paused Apple Music, so it stays paused until you press play.'
        }
        else {
            'Watching. Waiting for Apple Music to play.'
        }
        Set-Text $ui.HeroWatch $watch -Fade:($ui.HeroWatch.Text -notlike 'No sound for*' -or $watch -notlike 'No sound for*')
        Set-AnimatedBrush $ui.HeroDot 'Fill' $dot
        Set-AnimatedBrush $ui.PillDot 'Fill' $dot
        $pill = if (-not $State.Active) { 'Not watching' }
        elseif ($State.Phase -eq 'Offline') { 'Offline' }
        elseif ($State.Phase -eq 'Checking' -or ($State.Phase -eq 'Watching' -and $State.SilentSince)) { 'No sound' }
        elseif ($State.Phase -ne 'Watching') { 'Fixing' }
        else { 'Watching' }
        Set-Text $ui.PillText $pill -Fade
        $ui.ToggleWatch.Content = if ($State.Active) { 'Stop Watching' } else { 'Start Watching' }
        Set-AnimatedBrush $ui.ToggleWatch 'Background' $(if ($State.Active) { $colors.Raised } else { $colors.Accent })
        Set-AnimatedBrush $ui.ToggleWatch 'Foreground' $(if ($State.Active) { $colors.Text } else { '#FFFFFF' })

        Set-Text $ui.SidebarNote $(if ($Settings.CloseToTray) { 'Closing this window keeps the watchdog running in the tray.' } else { 'Closing this window stops the watchdog.' })

        # Stats
        Set-Text $ui.StatFixes $State.Fixes -Fade
        Set-Text $ui.StatFixesNote $(if ($State.Fixes) { 'Since {0:HH:mm}' -f $ui.OpenedAt } else { 'None yet' })

        # Last fix: what it did, to which song, and whether the sound came back.
        if ($State.LastFixAt) {
            Set-Text $ui.LastFixLabel ('Last fix, {0} at {1:HH:mm}' -f (Format-Ago $State.LastFixAt), $State.LastFixAt)
            $what = $fixNames[$State.LastFixKind]
            if (-not $what) { $what = 'Fixed' }
            if ($State.LastFixTitle) { $what = '{0} during {1}{2}{3}' -f $what, [char]0x201C, $State.LastFixTitle, [char]0x201D }
            Set-Text $ui.LastFixText $what -Fade
            $result, $color = if ($State.LastFixWorked) { 'Sound came back', $colors.Green }
            elseif ($State.LastFixCut) { 'Paused during the fix', $colors.Secondary }
            else { 'Still silent', $colors.Amber }
            Set-Text $ui.LastFixResult $result -Fade
            Set-AnimatedBrush $ui.LastFixResult 'Foreground' $color
            $ui.LastFixChip.Visibility = 'Visible'
        }
        else {
            Set-Text $ui.LastFixLabel 'Last fix'
            Set-Text $ui.LastFixText 'None yet. Fixes will show up here.'
            $ui.LastFixChip.Visibility = 'Collapsed'
        }
        Set-Text $ui.StatUptime $(if ($State.Active) { Format-Span ($now - $ui.ActiveSince) } else { 'Off' })
        Set-Text $ui.StatTimer $(if ($ui.Deadline) { Format-Span ($ui.Deadline - $now) } elseif ($ui.EndedAt) { 'Done' } else { 'Off' })

        # Settings
        Set-Text $ui.SilentValue (Format-SecondCount $Settings.SilentSeconds)
        Set-Text $ui.CooldownValue (Format-SecondCount $Settings.CooldownSeconds)
        $ui.SilentDown.IsEnabled = $Settings.SilentSeconds -gt 3
        $ui.SilentUp.IsEnabled = $Settings.SilentSeconds -lt 600
        $ui.CooldownDown.IsEnabled = $Settings.CooldownSeconds -gt 0
        $ui.CooldownUp.IsEnabled = $Settings.CooldownSeconds -lt 3600

        # Theme
        foreach ($choice in 'System', 'Light', 'Dark') {
            $chip = $ui["Theme$choice"]
            $on = $Settings.Theme -eq $choice
            Set-AnimatedBrush $chip 'Background' $(if ($on) { $colors.Accent } else { $colors.Raised })
            Set-AnimatedBrush $chip 'Foreground' $(if ($on) { '#FFFFFF' } else { $colors.Text })
        }

        # Timer
        $minutes = Get-TimerLength
        Set-Text $ui.HoursValue ('{0} hr' -f $Settings.StopAfterHours)
        Set-Text $ui.MinutesValue ('{0} min' -f $Settings.StopAfterMinutes)
        $on = $Settings.StopAfterEnabled
        $ui.TimerOptions.IsEnabled = $on
        Set-AnimatedOpacity $ui.TimerOptions $(if ($on) { 1 } else { 0.5 })
        $ui.PauseRow.IsEnabled = $on
        Set-AnimatedOpacity $ui.PauseRow $(if ($on) { 1 } else { 0.5 })
        $fadeOn = $on -and $Settings.PauseWhenDone
        $ui.FadeRow.IsEnabled = $fadeOn
        Set-AnimatedOpacity $ui.FadeRow $(if ($fadeOn) { 1 } else { 0.5 })
        foreach ($preset in 15, 30, 45, 60, 120, 240) {
            $chip = $ui["Preset$preset"]
            Set-AnimatedBrush $chip 'Background' $(if ($preset -eq $minutes) { $colors.Accent } else { $colors.Raised })
            Set-AnimatedBrush $chip 'Foreground' $(if ($preset -eq $minutes) { '#FFFFFF' } else { $colors.Text })
        }
        if ($ui.Deadline) {
            Set-Text $ui.TimerBig ('{0} left' -f (Format-Span ($ui.Deadline - $now)))
            $ending = if (-not $Settings.PauseWhenDone) { '' } elseif ($Settings.FadeOut) { ', fading Apple Music out and pausing it' } else { ' and pauses Apple Music' }
            Set-Text $ui.TimerSmall ('Stops at {0:HH:mm}{1}.' -f $ui.Deadline, $ending)
        }
        elseif ($ui.EndedAt) {
            Set-Text $ui.TimerBig 'Time''s up'
            Set-Text $ui.TimerSmall ('The timer ran out at {0:HH:mm}. Press Start Watching to go again.' -f $ui.EndedAt)
        }
        elseif ($on) {
            Set-Text $ui.TimerBig (Format-Duration $minutes)
            Set-Text $ui.TimerSmall 'Starts when the watchdog starts watching.'
        }
        else {
            Set-Text $ui.TimerBig 'Off'
            Set-Text $ui.TimerSmall 'The watchdog runs until you close this window.'
        }
    }

    function Set-ThemeChoice([string]$Choice) {
        $Settings.Theme = $Choice
        Save-WatchdogSetting
        Set-Palette (Test-UseDark)
        Update-PageFill
        Update-Display
    }
    $ui.ThemeSystem.Add_Click({ Set-ThemeChoice 'System' })
    $ui.ThemeLight.Add_Click({ Set-ThemeChoice 'Light' })
    $ui.ThemeDark.Add_Click({ Set-ThemeChoice 'Dark' })

    # Navigation
    $pages = @{ NavNow = $ui.PageNow; NavSettings = $ui.PageSettings }
    foreach ($page in $pages.Values) { [SmoothScroll]::Enable($page) }
    foreach ($nav in $pages.Keys) {
        $ui[$nav].Add_Checked({
                param($source)
                foreach ($key in $pages.Keys) {
                    if ($ui[$key] -eq $source) { Show-Page $pages[$key] }
                }
            })
    }

    # Settings
    $ui.KeepAwake.IsChecked = $Settings.KeepAwake
    $ui.StopAfter.IsChecked = $Settings.StopAfterEnabled
    $ui.PauseWhenDone.IsChecked = $Settings.PauseWhenDone
    $ui.FadeOut.IsChecked = $Settings.FadeOut
    $ui.CloseToTray.IsChecked = $Settings.CloseToTray
    $ui.RestartAppleMusic.IsChecked = $Settings.RestartAppleMusic
    $ui.RespectPause.IsChecked = $Settings.RespectPause
    $ui.Notify.IsChecked = $Settings.Notify

    $ui.SilentDown.Add_Click({ $Settings.SilentSeconds = Get-StepValue $Settings.SilentSeconds 3 600 $false $silentSteps; Save-WatchdogSetting; Update-Display })
    $ui.SilentUp.Add_Click({ $Settings.SilentSeconds = Get-StepValue $Settings.SilentSeconds 3 600 $true $silentSteps; Save-WatchdogSetting; Update-Display })
    $ui.CooldownDown.Add_Click({ $Settings.CooldownSeconds = Get-StepValue $Settings.CooldownSeconds 0 3600 $false $cooldownSteps; Save-WatchdogSetting; Update-Display })
    $ui.CooldownUp.Add_Click({ $Settings.CooldownSeconds = Get-StepValue $Settings.CooldownSeconds 0 3600 $true $cooldownSteps; Save-WatchdogSetting; Update-Display })
    # Switches react to being turned on or off, however that happens (mouse, keyboard or accessibility tools).
    $onKeepAwake = { $Settings.KeepAwake = [bool]$ui.KeepAwake.IsChecked; Save-WatchdogSetting }
    $onStopAfter = { $Settings.StopAfterEnabled = [bool]$ui.StopAfter.IsChecked; Save-WatchdogSetting; Reset-Deadline; Update-Display }
    $onPauseWhenDone = { $Settings.PauseWhenDone = [bool]$ui.PauseWhenDone.IsChecked; Save-WatchdogSetting; if (-not $Settings.PauseWhenDone) { Stop-Fade }; Update-Display }
    $ui.KeepAwake.Add_Checked($onKeepAwake); $ui.KeepAwake.Add_Unchecked($onKeepAwake)
    $ui.StopAfter.Add_Checked($onStopAfter); $ui.StopAfter.Add_Unchecked($onStopAfter)
    $ui.PauseWhenDone.Add_Checked($onPauseWhenDone); $ui.PauseWhenDone.Add_Unchecked($onPauseWhenDone)
    $onFadeOut = { $Settings.FadeOut = [bool]$ui.FadeOut.IsChecked; Save-WatchdogSetting; if (-not $Settings.FadeOut) { Stop-Fade }; Update-Display }
    $ui.FadeOut.Add_Checked($onFadeOut); $ui.FadeOut.Add_Unchecked($onFadeOut)
    $onCloseToTray = { $Settings.CloseToTray = [bool]$ui.CloseToTray.IsChecked; Save-WatchdogSetting; Update-Tray; Update-Display }
    $ui.CloseToTray.Add_Checked($onCloseToTray); $ui.CloseToTray.Add_Unchecked($onCloseToTray)
    # Start at sign-in is a scheduled task, not a saved setting (see Autostart.ps1), so
    # 'watchdog install' and this switch agree. Looked up once the window is showing,
    # since that takes a moment.
    $ui.SignInReady = $false
    $onStartAtSignIn = {
        if (-not $ui.SignInReady) { return }
        try {
            if ($ui.StartAtSignIn.IsChecked) {
                Register-WatchdogAutostart
                Add-LogLine 'The watchdog will start when you sign in'
            }
            else {
                Unregister-WatchdogAutostart
                Add-LogLine 'The watchdog will no longer start when you sign in'
            }
        }
        catch {
            Add-LogLine "Couldn't change starting at sign-in: $($_.Exception.Message)"
            Show-WatchdogError "Couldn't change whether the watchdog starts when you sign in: $($_.Exception.Message)"
            $ui.SignInReady = $false
            $ui.StartAtSignIn.IsChecked = Test-WatchdogAutostart
            $ui.SignInReady = $true
        }
    }
    $ui.StartAtSignIn.Add_Checked($onStartAtSignIn); $ui.StartAtSignIn.Add_Unchecked($onStartAtSignIn)
    $onRestartAppleMusic = { $Settings.RestartAppleMusic = [bool]$ui.RestartAppleMusic.IsChecked; Save-WatchdogSetting }
    $ui.RestartAppleMusic.Add_Checked($onRestartAppleMusic); $ui.RestartAppleMusic.Add_Unchecked($onRestartAppleMusic)
    $onRespectPause = { $Settings.RespectPause = [bool]$ui.RespectPause.IsChecked; Save-WatchdogSetting; Update-Display }
    $ui.RespectPause.Add_Checked($onRespectPause); $ui.RespectPause.Add_Unchecked($onRespectPause)
    $onNotify = { $Settings.Notify = [bool]$ui.Notify.IsChecked; Save-WatchdogSetting }
    $ui.Notify.Add_Checked($onNotify); $ui.Notify.Add_Unchecked($onNotify)
    $ui.HoursDown.Add_Click({ Set-TimerLength ((Get-TimerLength) - 60) })
    $ui.HoursUp.Add_Click({ Set-TimerLength ((Get-TimerLength) + 60) })
    $ui.MinutesDown.Add_Click({ Set-TimerLength ((Get-TimerLength) - 5) })
    $ui.MinutesUp.Add_Click({ Set-TimerLength ((Get-TimerLength) + 5) })
    foreach ($preset in 15, 30, 45, 60, 120, 240) {
        $ui["Preset$preset"].Tag = $preset
        $ui["Preset$preset"].Add_Click({ param($source) Set-TimerLength ([int]$source.Tag) })
    }
    $ui.PreviousButton.Add_Click({ Invoke-MediaButton 'Previous' })
    $ui.PlayButton.Add_Click({ Invoke-MediaButton 'PlayPause' })
    $ui.NextButton.Add_Click({ Invoke-MediaButton 'Next' })
    $ui.ToggleWatch.Add_Click({
            if ($State.Active) { Stop-Watching 'Stopped watching' } else { Start-Watching }
            Update-Display
        })

    $ui.Hero.Add_SizeChanged({
            $ui.Hero.Clip = New-Object System.Windows.Media.RectangleGeometry ((New-Object System.Windows.Rect 0, 0, $ui.Hero.ActualWidth, $ui.Hero.ActualHeight), 16, 16)
        })

    # The tray icon, shown while "Keep running in the tray when closed" is on.
    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Icon = New-Object System.Drawing.Icon ((New-Object System.IO.MemoryStream (, $iconData))), ([System.Windows.Forms.SystemInformation]::SmallIconSize)
    $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $trayOpen = $trayMenu.Items.Add('Open Apple Music Watchdog')
    $trayOpen.Font = New-Object System.Drawing.Font($trayOpen.Font, [System.Drawing.FontStyle]::Bold)
    [void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $traySong = $trayMenu.Items.Add('')
    $traySong.Enabled = $false
    $trayPlay = $trayMenu.Items.Add('Play')
    $trayNext = $trayMenu.Items.Add('Next')
    $trayPrevious = $trayMenu.Items.Add('Previous')
    [void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $trayToggle = $trayMenu.Items.Add('Start Watching')
    [void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $trayQuit = $trayMenu.Items.Add('Quit')
    $tray.ContextMenuStrip = $trayMenu
    $ui.Quitting = $false
    $ui.TrayHinted = $false

    function Update-Tray {
        $tray.Visible = $Settings.CloseToTray -or -not $window.IsVisible
        $tray.Text = if ($State.Active) { 'Apple Music Watchdog: watching' } else { 'Apple Music Watchdog: not watching' }
    }

    function Hide-ToTray {
        $window.Hide()
        Update-Tray
        if (-not $ui.TrayHinted) {
            $ui.TrayHinted = $true
            $tray.ShowBalloonTip(4000, 'Apple Music Watchdog', 'Still running here. Click the icon to open it, or right-click to quit.', 'None')
        }
    }

    function Show-FromTray {
        $window.Show()
        if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
        [void]$window.Activate()
        Update-Tray
        Update-Display
    }

    $trayOpen.Add_Click({ Show-FromTray })
    $trayToggle.Add_Click({
            if ($State.Active) { Stop-Watching 'Stopped watching' } else { Start-Watching }
            Update-Tray
        })
    $trayQuit.Add_Click({ $ui.Quitting = $true; $window.Close() })
    $trayPlay.Add_Click({ Invoke-MediaButton 'PlayPause' })
    $trayNext.Add_Click({ Invoke-MediaButton 'Next' })
    $trayPrevious.Add_Click({ Invoke-MediaButton 'Previous' })
    $trayMenu.Add_Opening({
            $trayToggle.Text = if ($State.Active) { 'Stop Watching' } else { 'Start Watching' }
            $hasApp = $State.Status -ne 'Not running'
            $song = if ($State.Title) { $State.Title } elseif ($hasApp) { 'Nothing playing' } else { 'Apple Music isn''t open' }
            if ($song.Length -gt 48) { $song = $song.Substring(0, 47) + '...' }
            $traySong.Text = $song.Replace('&', '&&')   # a single & would underline the next letter
            $trayPlay.Text = if ($State.Status -eq 'Playing') { 'Pause' } else { 'Play' }
            foreach ($item in $trayPlay, $trayNext, $trayPrevious) { $item.Enabled = $hasApp }
        })
    $tray.Add_MouseClick({ if ($_.Button -eq 'Left') { Show-FromTray } })

    # Opening the app again (shortcut or 'watchdog ui') sets this to bring the window back.
    $showEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\AppleMusicWatchdogShow')

    $ticker = New-Object System.Windows.Threading.DispatcherTimer
    $ticker.Interval = [TimeSpan]::FromMilliseconds(500)
    $ticker.Add_Tick({
            try {
                # 'watchdog stop' closes the window for good, even with the tray option on.
                if ($stopEvent.WaitOne(0)) { $ui.Quitting = $true; $window.Close(); return }
                if ($showEvent.WaitOne(0)) { Show-FromTray }
                # Following Windows: switch when Windows switches between light and dark.
                # Checked every few seconds; it's a quick registry read.
                $ui.ThemeCheck = 1 + $ui.ThemeCheck
                if ($ui.ThemeCheck % 6 -eq 0 -and $Settings.Theme -eq 'System' -and (Test-DarkTheme) -ne $ui.Dark) {
                    Set-Palette (Test-DarkTheme)
                    Update-PageFill
                }
                Invoke-WatchdogStep
                $now = Get-Date
                if ($ui.Deadline -and $Settings.PauseWhenDone -and $Settings.FadeOut -and $State.FadeFrom -lt 0 -and
                    $State.Status -eq 'Playing' -and $now -ge $ui.Deadline.AddSeconds(-$FadeSeconds) -and $now -lt $ui.Deadline) {
                    Start-Fade
                }
                if ($ui.Deadline -and $now -ge $ui.Deadline) { Stop-Session }
                if ($ui.RestoreAt -and $now -ge $ui.RestoreAt) {
                    if ($State.Status -eq 'Playing' -and -not $ui.PauseRetried) {
                        # Still playing after the fade: try pausing once more before turning
                        # the volume back up, rather than blasting the music at full volume.
                        $ui.PauseRetried = $true
                        $ui.RestoreAt = $now.AddSeconds(1.5)
                        $session = Get-AppleMusicSession $State.Manager
                        if ($session) { [void](Wait-AsyncOperation ($session.TryPauseAsync()) ([bool])) }
                        Add-LogLine 'Apple Music was still playing after the timer. Pausing it again.'
                    }
                    else { Stop-Fade }
                }
                # No need to redraw while the window is minimised or hidden in the tray.
                if ($window.IsVisible -and $window.WindowState -ne 'Minimized') { Update-Display } else { Update-Tray }
            }
            catch {
                Add-LogLine "Error: $($_.Exception.Message)"
            }
        })
    $window.Add_Closing({
            # With the tray option on, the close button hides the window instead.
            if ($Settings.CloseToTray -and -not $ui.Quitting) {
                $_.Cancel = $true
                Hide-ToTray
                return
            }
            $ticker.Stop()
            $fadeTimer.Stop()
            $wave.Stop()
        })
    $window.Add_ContentRendered({
            Start-Animation $ui.Shell ([System.Windows.UIElement]::OpacityProperty) 1 350 0
            try { Update-WatchdogShortcut $iconData }
            catch { Add-LogLine "Couldn't create the Apple Music Watchdog shortcuts: $($_.Exception.Message)" }
            try { $ui.StartAtSignIn.IsChecked = Test-WatchdogAutostart }
            catch { Add-LogLine "Couldn't check whether the watchdog starts at sign-in: $($_.Exception.Message)" }
            $ui.SignInReady = $true
        })

    Reset-Deadline
    Invoke-WatchdogStep
    Update-Display
    $ticker.Start()
    $wave.Start()

    # Run until the window is closed for good. (Not ShowDialog, so the window can hide.)
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $window.Add_Closed({ $frame.Continue = $false })
    $window.Show()
    Update-Tray
    try {
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    }
    finally {
        $tray.Visible = $false
        $tray.Dispose()
        $showEvent.Dispose()
    }
}

# The artwork's two main colours, for filling Now Playing: the most common colour,
# and the most common one that's clearly different (or the first again if there
# isn't one). Bright, colourful pixels count for more, so a colourful cover isn't
# summed up by its grey background, but a black-and-white cover still gives greys.
# Near-black or near-white only leads if there's no real colour in a good share of
# the cover, so a cover that's mostly shadow still gets its colour.
function Get-ArtworkPalette($Image) {
    $scale = New-Object System.Windows.Media.ScaleTransform (32.0 / $Image.PixelWidth), (32.0 / $Image.PixelHeight)
    $small = New-Object System.Windows.Media.Imaging.TransformedBitmap $Image, $scale
    $pixels = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap $small, ([System.Windows.Media.PixelFormats]::Bgra32), $null, 0
    $bytes = New-Object byte[] ($pixels.PixelWidth * $pixels.PixelHeight * 4)
    $pixels.CopyPixels($bytes, $pixels.PixelWidth * 4, 0)
    # Group similar colours: 8 levels each of red, green and blue.
    $weight = New-Object double[] 512
    $red = New-Object double[] 512
    $green = New-Object double[] 512
    $blue = New-Object double[] 512
    for ($i = 0; $i -lt $bytes.Length; $i += 4) {
        $b = [int]$bytes[$i]; $g = [int]$bytes[$i + 1]; $r = [int]$bytes[$i + 2]
        $max = [Math]::Max($r, [Math]::Max($g, $b))
        $min = [Math]::Min($r, [Math]::Min($g, $b))
        $w = if ($max -gt 0) { 1.0 + 3.0 * ($max - $min) / 255.0 } else { 1.0 }
        $group = (($r -shr 5) -shl 6) -bor (($g -shr 5) -shl 3) -bor ($b -shr 5)
        $weight[$group] += $w
        $red[$group] += $r * $w
        $green[$group] += $g * $w
        $blue[$group] += $b * $w
    }
    $first = 0
    for ($i = 1; $i -lt 512; $i++) { if ($weight[$i] -gt $weight[$first]) { $first = $i } }
    $average = { param($n) [System.Windows.Media.Color]::FromRgb([byte]($red[$n] / $weight[$n]), [byte]($green[$n] / $weight[$n]), [byte]($blue[$n] / $weight[$n])) }
    $isExtreme = { param($c) [Math]::Max($c.R, [Math]::Max($c.G, $c.B)) -lt 48 -or [Math]::Min($c.R, [Math]::Min($c.G, $c.B)) -gt 225 }
    if (& $isExtreme (& $average $first)) {
        $best = $null
        for ($i = 0; $i -lt 512; $i++) {
            if ($weight[$i] -lt $weight[$first] * 0.15 -or (& $isExtreme (& $average $i))) { continue }
            if ($null -eq $best -or $weight[$i] -gt $weight[$best]) { $best = $i }
        }
        if ($null -ne $best) { $first = $best }
    }
    $main = & $average $first
    $second = $null
    for ($i = 0; $i -lt 512; $i++) {
        if ($weight[$i] -lt $weight[$first] * 0.05) { continue }
        $color = & $average $i
        $distance = [Math]::Sqrt([Math]::Pow($color.R - $main.R, 2) + [Math]::Pow($color.G - $main.G, 2) + [Math]::Pow($color.B - $main.B, 2))
        if ($distance -gt 64 -and ($null -eq $second -or $weight[$i] -gt $weight[$second])) { $second = $i }
    }
    $other = if ($null -ne $second) { & $average $second } else { $main }
    , @($main, $other)
}

# An artwork colour turned into a background that text stays readable on: dark and
# not too vivid for the dark theme, pale for the light one. Keeps the colour's hue.
function ConvertTo-PageColor([System.Windows.Media.Color]$Color, [bool]$Dark) {
    $r = $Color.R / 255.0; $g = $Color.G / 255.0; $b = $Color.B / 255.0
    $max = [Math]::Max($r, [Math]::Max($g, $b)); $min = [Math]::Min($r, [Math]::Min($g, $b))
    $lightness = ($max + $min) / 2
    $chroma = $max - $min
    if ($chroma -lt 0.06) { $chroma = 0.0 }   # near-grey: keep it grey, not faintly tinted
    $saturation = if ($chroma -eq 0) { 0.0 } else { [Math]::Min(1.0, $chroma / (1 - [Math]::Abs(2 * $lightness - 1))) }
    $hue = if ($chroma -eq 0) { 0.0 }
    elseif ($max -eq $r) { 60 * ((($g - $b) / $chroma) % 6) }
    elseif ($max -eq $g) { 60 * (($b - $r) / $chroma + 2) }
    else { 60 * (($r - $g) / $chroma + 4) }
    if ($hue -lt 0) { $hue += 360 }
    if ($Dark) {
        $lightness = [Math]::Min(0.32, [Math]::Max(0.14, 0.06 + 0.8 * $lightness))
        $saturation = [Math]::Min(0.6, $saturation)
    }
    else {
        $lightness = 0.80 + 0.12 * $lightness
        $saturation = [Math]::Min(0.50, $saturation)
    }
    # Back to red, green and blue.
    $c = (1 - [Math]::Abs(2 * $lightness - 1)) * $saturation
    $x = $c * (1 - [Math]::Abs((($hue / 60) % 2) - 1))
    $m = $lightness - $c / 2
    $rgb = switch ([int][Math]::Floor($hue / 60) % 6) {
        0 { $c, $x, 0.0 }
        1 { $x, $c, 0.0 }
        2 { 0.0, $c, $x }
        3 { 0.0, $x, $c }
        4 { $x, 0.0, $c }
        default { $c, 0.0, $x }
    }
    [System.Windows.Media.Color]::FromRgb([byte](255 * ($rgb[0] + $m)), [byte](255 * ($rgb[1] + $m)), [byte](255 * ($rgb[2] + $m)))
}

# Reads a song's album art (a Windows media thumbnail) into an image the window can show.
function Read-Artwork($Reference) {
    $stream = Wait-AsyncOperation ($Reference.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
    try {
        $asStream = [System.IO.WindowsRuntimeStreamExtensions].GetMethod('AsStreamForRead', [Type[]]@([Windows.Storage.Streams.IInputStream]))
        $source = $asStream.Invoke($null, @($stream))
        $buffer = New-Object System.IO.MemoryStream
        $source.CopyTo($buffer)
        $source.Dispose()
    }
    finally {
        # PowerShell can't call Dispose on Windows Runtime objects; release it directly.
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($stream)
    }
    $buffer.Position = 0
    $image = New-Object System.Windows.Media.Imaging.BitmapImage
    $image.BeginInit()
    $image.CacheOption = 'OnLoad'
    $image.StreamSource = $buffer
    $image.EndInit()
    $image.Freeze()
    $image
}

# The artwork, blurred, for the background of the Now Playing card. Drawn once per
# song as a small picture that gets stretched to fit. A live blur effect looked the
# same but was redrawn on every frame while scrolling, which made scrolling stutter.
function New-BlurredArtwork($Image) {
    $size = 200
    $zoom = 1.3   # drawn larger than the picture, so the blur doesn't fade out at the edges
    $art = New-Object System.Windows.Controls.Border
    $art.Width = $art.Height = $size * $zoom
    $fill = New-Object System.Windows.Media.ImageBrush $Image
    $fill.Stretch = 'UniformToFill'
    $art.Background = $fill
    $blur = New-Object System.Windows.Media.Effects.BlurEffect
    $blur.Radius = 12
    $art.Effect = $blur
    $frame = New-Object System.Windows.Controls.Canvas
    [void]$frame.Children.Add($art)
    [System.Windows.Controls.Canvas]::SetLeft($art, - $size * ($zoom - 1) / 2)
    [System.Windows.Controls.Canvas]::SetTop($art, - $size * ($zoom - 1) / 2)
    $frame.Measure((New-Object System.Windows.Size $size, $size))
    $frame.Arrange((New-Object System.Windows.Rect 0, 0, $size, $size))
    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $size, $size, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($frame)
    $bitmap.Freeze()
    $bitmap
}

# The app icon: a white rounded tile with the watchdog symbol in black, like the
# Apple Music icon. Drawn at one size, as a PNG.
function New-WatchdogIconImage([int]$Size) {
    $visual = New-Object System.Windows.Media.DrawingVisual
    $context = $visual.RenderOpen()
    $edge = New-Object System.Windows.Media.Pen ((New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(40, 0, 0, 0)))), 1
    $radius = $Size * 0.22
    $context.DrawRoundedRectangle([System.Windows.Media.Brushes]::White, $edge, (New-Object System.Windows.Rect 0.5, 0.5, ($Size - 1), ($Size - 1)), $radius, $radius)
    $typeface = New-Object System.Windows.Media.Typeface 'Segoe Fluent Icons, Segoe MDL2 Assets'
    $glyph = New-Object System.Windows.Media.FormattedText ([string][char]0xE9D9), ([Globalization.CultureInfo]::InvariantCulture), 'LeftToRight', $typeface, ($Size * 0.56), ([System.Windows.Media.Brushes]::Black)
    $context.DrawText($glyph, (New-Object System.Windows.Point (($Size - $glyph.Width) / 2), (($Size - $glyph.Height) / 2)))
    $context.Close()
    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $Size, $Size, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = New-Object System.IO.MemoryStream
    $encoder.Save($stream)
    , $stream.ToArray()
}

# The app icon as .ico file data, at every size Windows asks for.
function New-WatchdogIconData {
    $sizes = 16, 20, 24, 32, 40, 48, 64, 256
    $images = foreach ($size in $sizes) { , (New-WatchdogIconImage $size) }
    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter $stream
    $writer.Write([uint16]0)              # reserved
    $writer.Write([uint16]1)              # type: icon
    $writer.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $side = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }   # 0 means 256
        $writer.Write([byte]$side)
        $writer.Write([byte]$side)
        $writer.Write([byte]0)            # no palette
        $writer.Write([byte]0)            # reserved
        $writer.Write([uint16]1)          # colour planes
        $writer.Write([uint16]32)         # bits per pixel
        $writer.Write([uint32]$images[$i].Length)
        $writer.Write([uint32]$offset)
        $offset += $images[$i].Length
    }
    foreach ($image in $images) { $writer.Write([byte[]]$image) }
    $writer.Flush()
    , $stream.ToArray()
}

# Saves the icon, and an "Apple Music Watchdog" shortcut in the project folder and the
# Start menu. They open the window directly, with no console window flashing up, and
# share the window's taskbar identity, so pinning the window pins the shortcut.
function Update-WatchdogShortcut([byte[]]$IconData) {
    $dir = Split-Path $IconPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $existing = if (Test-Path $IconPath) { [IO.File]::ReadAllBytes($IconPath) } else { $null }
    if (-not $existing -or [Convert]::ToBase64String($existing) -ne [Convert]::ToBase64String($IconData)) {
        [IO.File]::WriteAllBytes($IconPath, $IconData)
    }

    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script = Join-Path $PSScriptRoot 'AppleMusicWatchdog.ps1'
    # conhost --headless runs PowerShell with no console window at all.
    $arguments = '--headless "{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Window' -f $powershell, $script
    $places = @(
        (Join-Path (Split-Path $PSScriptRoot) $ShortcutName),
        (Join-Path ([Environment]::GetFolderPath('Programs')) $ShortcutName)
    )
    foreach ($place in $places) {
        [WindowsShell]::SaveShortcut($place, $conhost, $arguments, $PSScriptRoot, $IconPath,
            'Keeps Apple Music playing when it goes silent', $AppId)
    }
}
