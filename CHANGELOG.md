# Lens changelog

## 1.5
- APPLE mode no longer uses the 60 fps camera format. That format can disable Deep Fusion / full Smart HDR, which is likely why APPLE shots looked weaker than the stock camera. With APPLE on, the viewfinder runs at 30 fps on the standard photo format.

## 1.4
- Removed the "60" label from the viewfinder (the 60 fps preview itself stays).
- Portrait: Lens now picks a camera format that supports depth, sets its depth format and turns depth delivery on after the format change. Before, depth was switched on too early, so Portrait reported "Depth not available". If a lens still has no depth, the message now names the camera.

## 1.3
- RAW: captures are now exposed 1 stop lower to protect highlights (DNG files were coming out too bright).
- 60 fps viewfinder: smoother preview when the camera has a 4:3 full-resolution format that supports it (a "60" shows top-left when active). Portrait and RAW stay at 30 fps.
- New APPLE button (Photo mode): turns on Apple's own image processing (Smart HDR, Deep Fusion, tone mapping) and saves as HEIC. It switches RAW off.
- New STEADY button: after you press the shutter, Lens waits for the motion sensors to show the phone has stopped shaking, then takes the photo. Tap the shutter again to cancel; it gives up and shoots after 2.5 s.

## 1.2
- Removed the M button and the manual ISO / shutter sliders. Exposure is fully automatic.
- Renamed "Night" mode to "Low Light".
- Front camera flash: when flash is on (or Auto in dim light) the screen turns white at full brightness, the photo is taken, then your brightness is restored.
- Flash button now shows on the front camera.
- Portrait rebuilt on Apple's native depth blur (CIDepthBlurEffect with the camera's own depth map). Blur is focused where you tap. Saves the original plus the blurred photo, and shows "Depth not available" if the lens can't supply depth.

## 1.1
- New Apple-style layout: rounded 3:4 viewfinder, mode selector, thumbnail / shutter / flip row, lens chips, haptics.
- Added Portrait and Night modes.
- Generated app icon.

## 1.0
- First native version: unprocessed PNG and RAW capture, lens switching, tap to focus, pinch zoom, mirrored selfies, saves to Photos.
