# Lens changelog

## 1.6.3 (hotfix)
- PNG photos were saving at about 2 MP. The 60 fps camera format defaults to a small still size, so Lens now asks for the largest still size the format supports (12 MP on the iPhone 13) for every capture: Photo, Portrait, Apple and each Low Light frame. RAW and Apple were already 12 MP.
- Low Light now processes 12 MP frames, so it takes a little longer to finish.

## 1.6.1 (hotfix)
- The big circles behind the last-photo thumbnail and the camera-switch button were iOS adding its own button background, not Lens. All buttons now use a flat style, so the circles are gone.
- Volume buttons: the button handler now goes through one debounced path, and a fallback watches the volume level in case the system doesn't deliver button events. Pressing either volume button should take the photo in every mode.
- Portrait: new LOW to HIGH slider under the viewfinder controls how strong the background blur is. It changes the live preview immediately and is used for the saved photo.
- A small "Lens 1.6.1" toast shows when the app opens, so you can confirm which build is installed. Zoom stops (0.5 / 1 / 2), the exact zoom readout and the pinch badge from 1.6 are unchanged; if you don't see them, the new build isn't installed yet.

## 1.6
- Portrait: the blur was landing on the subject. Portrait now builds its own depth mask (sharp at the depth you tap, blurred everywhere else, including far backgrounds) instead of Apple's blur filter, whose focus-area setting was almost certainly the cause. Tap the subject to choose what stays sharp.
- Portrait: real-time blur in the viewfinder, using the same depth mask as the saved photo.
- Removed the circle background behind the last-photo thumbnail and the camera-switch button.
- Sounds: the system shutter is silenced where iOS allows it and replaced by a soft modern click. Low Light plays a calm ambient pad while it captures, then a gentle chime, instead of one click per frame. Sounds follow the silent switch.
- Zoom: added a 2x stop (0.5 / 1 / 2). The selected stop shows the exact zoom (for example 1.7x), and a zoom badge appears while pinching.
- Volume buttons (and Camera Control on supported phones) now take the photo in every mode.

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
