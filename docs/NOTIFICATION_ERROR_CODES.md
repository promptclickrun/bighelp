# Notification setup error codes

When notification setup stops, bighelp shows a short message and a code, for example `NS-102`.
The message tells you what to do. The code tells us which step stopped and why.
Use this page to find your code.

## Where you see the code

bighelp shows the code in these places:

- The Notifications section of the screen for a computer.
- **Settings › Notifications**.
- The Notifications step of the first setup.
- **Settings › Notifications › Advanced › Provider details**. This row shows the last problem and its time.

## How to send us a code

1. Find the code on the screen.
2. Tap **Copy Details**.
3. Paste the text in a GitHub issue or in a message to us.

The copied text contains these items only:

- The code.
- The setup step that stopped.
- The type of error and its number, for example `URLError -1003` or `HTTP 409 notification_bootstrap_conflict`.
- The version and build of bighelp.
- The name and version of the system on your device.

The copied text does not contain the address of your computer, your name, a token or an identifier.

## Words on this page

| Word | Meaning |
|---|---|
| device | Your iPhone, iPad, Mac or Apple Vision Pro. |
| computer | The computer that runs Hermes. |
| plugin | The bighelp plugin for Hermes. |
| notification service | The bighelp service that connects your computer to your device. |
| push service | The service that sends notifications to your device. |
| notification permission | The record that lets one computer send notifications to your device. |

## How the codes work

The first digit tells you which part stopped:

| Codes | Part |
|---|---|
| NS-1xx | The notification service, and the sign-up of your device with it. |
| NS-2xx | Your device: permission, push registration, the push service and saved data. |
| NS-3xx | The computer: the connection, the plugin and Hermes. |
| NS-4xx | Notification permissions. |
| NS-5xx | **Turn Off Notifications** and **Set Up Again**. |
| NS-9xx | Other problems. |

A code always keeps its meaning. A new problem gets a new code.
Network problems use the code of the service that bighelp cannot reach. The copied details show the step.

Some problems do not go away when you try again. For these problems, bighelp does not show **Check Again**. The message tells you what to do.

## NS-1xx: the notification service

| Code | What happened | What to do | What we need |
|---|---|---|---|
| NS-101 | Your device has no internet connection. | Connect to Wi-Fi or mobile data. Then try again. | Nothing. |
| NS-102 | Your device cannot find or connect to the notification service. A VPN, a DNS filter or a firewall can block it. | Make sure that your device is online. Let your VPN or filter allow `link.loopdy.app`. Then try again. | If the problem continues, the code and its details. |
| NS-103 | The notification service did not answer in time. | Wait one minute. Then try again. | Nothing. |
| NS-104 | Your device cannot make a secure connection to the notification service. A wrong clock or a filter that inspects web traffic can cause this. | Make sure that the date and time on your device are correct. Stop any VPN or filter that inspects web traffic. Then try again. | If the problem continues, the code and its details. |
| NS-105 | The answer from the notification service was not usable. A Wi-Fi sign-in page often causes this. | Sign in to the Wi-Fi network in Safari, or use a different network. Then try again. | If the problem continues, the code and its details. |
| NS-106 | The notification service has a problem. | Try again later. | If the problem continues for more than one hour, the code and its details. |
| NS-107 | The notification service is busy. | Wait some minutes. Then try again. | Nothing. |
| NS-108 | A different network problem stopped setup. | Examine the connection of your device. Then try again. | If the problem continues, the code and its details. |
| NS-109 | The notification service does not accept a request from this version of bighelp. | Update bighelp. | The code and its details. |
| NS-110 | The notification service refused a step for a reason that this version of bighelp does not know. | Update bighelp. | The code and its details. |
| NS-111 | The notification service has a different key for your device. | Tap **Turn Off Notifications** at the bottom of **Settings › Notifications**. Then turn notifications on again. | If the problem continues, the code and its details. |
| NS-112 | The notification service received the same sign-up two times. | Try again. | Nothing. |
| NS-113 | The clock on your device is wrong. | Open the Settings app. Go to **General › Date & Time**. Set **Set Automatically** to on. Then try again. | Nothing. |
| NS-114 | Your network sent too many sign-ups in one hour. | Wait one hour. Then try again. | Nothing. |
| NS-115 | The notification service cannot accept new sign-ups now. | Try again later. | If the problem continues for more than one hour, the code and its details. |
| NS-116 | The notification service did not accept the new key of your device. | Update bighelp. | The code and its details. |
| NS-117 | The notification service did not accept the sign-in of your device. Usually the clock on your device is wrong. | Set **Set Automatically** to on in **General › Date & Time**. Then try again. | If the clock is correct, the code and its details. |
| NS-118 | The notification service stopped the sign-up of your device. | Tap **Turn Off Notifications**. Then turn notifications on again. | If the problem continues, the code and its details. |
| NS-119 | The notification service did not accept the notification key of your device. | Tap **Turn Off Notifications**. Then turn notifications on again. | If the problem continues, the code and its details. |
| NS-120 | The notification service received the same request two times. | Try again. | Nothing. |
| NS-121 | The notification service did not confirm that it removed an old sign-up of your device. | Try again later. | If the problem continues, the code and its details. |
| NS-122 | The notification service could not remove your device from the push service. | Try again later. | If the problem continues, the code and its details. |

## NS-2xx: your device

| Code | What happened | What to do | What we need |
|---|---|---|---|
| NS-201 | Notifications for bighelp are off on your device. | Open the Settings app. Go to **Notifications › bighelp**. Set **Allow Notifications** to on. Then try again. | Nothing. |
| NS-202 | The system on your device did not answer the request for notifications. | Try again. | If the problem continues, the code and its details. |
| NS-203 | The system on your device could not register the device for notifications. | Make sure that your device is online and signed in to your Apple Account. Restart the device. Then try again. | If the problem continues, the code and its details. |
| NS-204 | The system on your device did not register the device in time. | Examine the connection of your device. Then try again. | If the problem continues, the code and its details. |
| NS-205 | bighelp did not get the notification address of your device from the system. | Try again. | If the problem continues, the code and its details. |
| NS-206 | The push service could not register your device. | Wait one minute. Then try again. | If the problem continues, the code and its details. |
| NS-207 | The push service did not confirm the registration of your device. | Try again. | If the problem continues, the code and its details. |
| NS-208 | bighelp could not move your saved alert choices to the push service. | Try again. | If the problem continues, the code and its details. |
| NS-209 | The registration of your device did not finish before the check. | Try again. | If the problem continues, the code and its details. |
| NS-210 | The sign-in of your device with the push service stopped during setup. | Try again. | If the problem continues, the code and its details. |
| NS-211 | Your device cannot connect to the push service. A VPN or a DNS filter can block it. | Make sure that your device is online. Let your VPN or filter allow `api.buzzkit.dev` and Apple push notifications. Then try again. | If the problem continues, the code and its details. |
| NS-212 | The push service did not accept the sign-in of your device. | Wait one minute. Then try again. | If the problem continues, the code and its details. |
| NS-213 | The answer from the push service was not usable. | Try again later. | If the problem continues, the code and its details. |
| NS-214 | The push service did not start in bighelp. | Close bighelp fully and open it again. | If the problem continues, the code and its details. |
| NS-215 | This copy of bighelp cannot use notifications. It has no push service key. | Install bighelp from the App Store or from TestFlight. | Nothing. |
| NS-216 | This copy of bighelp cannot use notifications. Its push service address is not correct. | Install bighelp from the App Store or from TestFlight. | Nothing. |
| NS-217 | bighelp changed how it gets notifications while it was open. | Close bighelp fully and open it again. | Nothing. |
| NS-218 | bighelp does not know which push service to use. | Close bighelp fully and open it again. | If the problem continues, the code and its details. |
| NS-219 | bighelp is in demo mode. Demo mode does not have notifications. | Connect a real computer. | Nothing. |
| NS-220 | The notification service is not ready to send notifications. | Try again later. | If the problem continues for more than one hour, the code and its details. |
| NS-221 | The push service does not know your device yet. | Wait one minute. Then try again. | If the problem continues, the code and its details. |
| NS-222 | The push service did not confirm the sign-in of your device yet. | Wait one minute. Then try again. | If the problem continues, the code and its details. |
| NS-223 | The notification service cannot send to this type of bighelp build now. | Try again later. | The code and its details. |
| NS-224 | The push service has a different notification address for your device. | Try again. | If the problem continues, the code and its details. |
| NS-225 | The push service has notifications off for your device. | Make sure that notifications for bighelp are on in the Settings app. Then try again. | If the problem continues, the code and its details. |
| NS-226 | The push service shows your device as not active. | Try again. | If the problem continues, the code and its details. |
| NS-227 | The push service has your device registered for a different type of build, for example TestFlight instead of the App Store. | Try again. | If the problem continues, the code and its details. |
| NS-228 | The push service does not have all alert types for your device yet. | Wait one minute. Then try again. | If the problem continues, the code and its details. |
| NS-229 | The push service confirmed a different registration for your device. | Try again. | If the problem continues, the code and its details. |
| NS-230 | The check of your device by the push service failed for a different reason. | Wait one minute. Then try again. | If the problem continues, the code and its details. |
| NS-231 | The notification service cannot connect to the push service. | Try again later. | If the problem continues for more than one hour, the code and its details. |
| NS-232 | The push service sent the notification service data that it cannot use. | Try again later. | If the problem continues, the code and its details. |
| NS-233 | The records of the push service for your device do not agree. | Try again. | If the problem continues, the code and its details. |
| NS-234 | The push service has more than one registration for your device. | Tap **Turn Off Notifications**. Then turn notifications on again. | If the problem continues, the code and its details. |
| NS-235 | The notification service cannot use the push service now. Its configuration is not complete. | Try again later. | The code and its details. |
| NS-240 | bighelp cannot open the keychain on your device. The device is possibly locked. | Unlock your device. Then try again. | If the problem continues, the code and its details. |
| NS-241 | The notification setup that bighelp saved on your device is damaged. | Tap **Turn Off Notifications**. Then turn notifications on again. | If the problem continues, the code and its details. |
| NS-242 | bighelp cannot save the notification setup on your device. | Make sure that your device has free storage. Then try again. | If the problem continues, the code and its details. |
| NS-243 | bighelp cannot load the notification setup on your device. | Close bighelp fully and open it again. | If the problem continues, the code and its details. |

## NS-3xx: the computer

| Code | What happened | What to do | What we need |
|---|---|---|---|
| NS-301 | bighelp cannot connect to your computer. | Make sure that the computer is on and that Hermes runs. Then try again. | Nothing. |
| NS-302 | bighelp lost the connection to your computer. | Examine the address of the computer, your VPN or Tailscale, and Hermes. Then try again. | If the problem continues, the code and its details. |
| NS-303 | Your computer did not answer in time. | Try again. | If the problem continues, the code and its details. |
| NS-304 | bighelp cannot verify the secure connection to your computer. | Examine the HTTPS certificate of the computer. Then try again. | Nothing. |
| NS-305 | Your computer sent an answer that bighelp cannot read. | Update the plugin on the computer. Then try again. | If the problem continues, the code, its details and the Hermes log from the same time. |
| NS-306 | Hermes on your computer had a problem. | Read the Hermes log. Then try again. | If the problem continues, the code, its details and the Hermes log from the same time. |
| NS-307 | Your computer received too many requests. | Wait one minute. Then try again. | Nothing. |
| NS-308 | Your computer did not accept the sign-in of bighelp. | Sign in to the computer again. Then try again. | If the problem continues, the code and its details. |
| NS-309 | The plugin on your computer does not have its notification part. | Update the plugin. Restart Hermes. Then try again. | If the problem continues, the code and its details. |
| NS-310 | The sign-in for your computer changed. | Sign in to the computer again. Then try again. | Nothing. |
| NS-311 | The plugin refused a step for a reason that this version of bighelp does not know. | Update the plugin. Then try again. | The code, its details and the Hermes log from the same time. |
| NS-312 | The plugin does not accept a request from this version of bighelp. | Update bighelp and the plugin. | The code and its details. |
| NS-320 | bighelp cannot get the newest plugin from GitHub. | Examine the internet connection of your device. Then try again. | If the problem continues, the code and its details. |
| NS-321 | Your computer has more than one bighelp plugin. | Remove the extra plugin in Hermes. Then try again. | Nothing. |
| NS-322 | An earlier plugin install on your computer did not finish. | Tap **Set Up Again** in **Settings › Notifications**. | If the problem continues, the code and its details. |
| NS-323 | This version of Hermes cannot install plugins for bighelp. | Update Hermes, or install the plugin on the computer. Then try again. | Nothing. |
| NS-324 | Your computer does not let bighelp install plugins. | Allow plugin installs in Hermes, or install the plugin on the computer. Then try again. | Nothing. |
| NS-325 | Hermes refused the plugin. | Read the reason in Hermes. Then try again. | If the problem continues, the code, its details and the Hermes log from the same time. |
| NS-326 | Hermes refused to change its plugins. | Read the reason in Hermes. Then try again. | If the problem continues, the code, its details and the Hermes log from the same time. |
| NS-327 | The plugin install can still run on your computer. | Wait one minute. Then try again. | Nothing. |
| NS-328 | Your computer did not confirm the plugin install. | Try again. If the problem continues, tap **Set Up Again**. | If the problem continues, the code, its details and the Hermes log from the same time. |
| NS-329 | The plugin did not start. | Turn on the plugin in Hermes. Then try again. | If the problem continues, the code and its details. |
| NS-330 | Hermes does not show the notification part of the plugin yet. | Restart the `hermes serve` process on the computer, not only the messaging gateway. Then try again. | Nothing. |
| NS-331 | The plugin on your computer is too old for notifications. | Update the plugin. Then try again. | Nothing. |
| NS-340 | Your computer cannot connect to the notification service. | Examine the internet connection of the computer. Let its firewall allow `link.loopdy.app`. Then try again. | If the problem continues, the code and its details. |
| NS-341 | The network of your computer sent its connection to a different place. | Examine the proxy settings of the computer. Then try again. | If the problem continues, the code and its details. |
| NS-342 | Your computer got an answer from the notification service that it cannot read. | Examine the network and proxy of the computer. Then try again. | If the problem continues, the code and its details. |
| NS-343 | The notification service refused a request from your computer. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-344 | The notification permission does not agree with the key of your computer. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-345 | Your computer got a notification permission that it cannot read. | Try again later. | If the problem continues, the code and its details. |
| NS-346 | Your computer shows that the notification permission expired. A wrong clock on the computer can cause this. | Make sure that the clock of the computer is correct. Then tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-347 | Your computer sends notifications to the maximum number of devices. | Send us the code. | The code and its details. |
| NS-348 | Your computer has a different copy of the notification permission for your device. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-349 | The plugin cannot keep its notification files private on your computer. | Examine the permissions of the Hermes home folder. Then try again. | If the problem continues, the code and its details. |
| NS-350 | Hermes runs on a system that bighelp notifications do not support yet. | Send us the code. | The code, its details and the system of the computer. |
| NS-351 | The notification key of the plugin on your computer is damaged. | Send us the code. | The code, its details and the Hermes log from the same time. |
| NS-352 | Your computer does not have the notification permission for your device now. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-353 | The copy of the notification permission on your computer changed. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-354 | Your computer did not accept the alert key of your device. | Update bighelp. | The code and its details. |
| NS-355 | Your computer refused alerts for the agent of the open chat. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-356 | Your computer could not start alerts for the open chat. | Try again. | If the problem continues, the code and its details. |
| NS-360 | Your computer confirmed a different notification permission. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-361 | The notification setup on your computer changed during the check. | Try again. | If the problem continues, the code and its details. |
| NS-362 | Your computer did not confirm the alert key of your device. | Try again. | If the problem continues, the code and its details. |
| NS-363 | Your computer did not confirm alerts for the open chat. | Try again. | If the problem continues, the code and its details. |

## NS-4xx: notification permissions

| Code | What happened | What to do | What we need |
|---|---|---|---|
| NS-401 | The notification service has an earlier request with different details for this computer. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-402 | Your device has too many notification permissions, or two permissions are in conflict. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-403 | The notification service does not know the notification permission for this computer. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-404 | The notification permission changed while bighelp updated it. | Try again. | Nothing. |
| NS-405 | A different notification permission uses the key of this computer. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-406 | The clock on your device is wrong. | Open the Settings app. Go to **General › Date & Time**. Set **Set Automatically** to on. Then try again. | Nothing. |
| NS-407 | The notification permission for this computer is not active. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-408 | The notification sign-up of your device is from an old version of bighelp. | Tap **Turn Off Notifications**. Then turn notifications on again. | If the problem continues, the code and its details. |
| NS-409 | The notification sign-up of your device uses a type of sign-in that bighelp removed. | Tap **Turn Off Notifications**. Then turn notifications on again. | If the problem continues, the code and its details. |
| NS-420 | The notification key of your computer changed after the setup of your device. A new plugin install can cause this. | Tap **Set Up Again**. | Nothing. |
| NS-421 | The notification service did not confirm that it removed an old notification permission. | Try again. | If the problem continues, the code and its details. |
| NS-422 | Your computer has more than one old notification permission. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-423 | Your computer has more than one notification permission for your device. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-424 | The notification permission does not agree with the permission that your device saved. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-425 | The permission request that your device saved is damaged or old. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-426 | The new notification permission does not agree with the request. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-427 | The notification permission did not pass the checks of bighelp. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-428 | The notification permission belongs to a different computer on your device. | Tap **Set Up Again**. | If the problem continues, the code and its details. |
| NS-429 | An earlier change to notifications did not finish. | Wait one minute. Then try again. | If the problem continues, the code and its details. |

## NS-5xx: Turn Off Notifications and Set Up Again

**Turn Off Notifications** shows these codes when it cannot finish:

| Code | What happened | What to do | What we need |
|---|---|---|---|
| NS-501 | bighelp cannot connect to the notification service. Notifications are not fully off. | Examine the connection of your device. Then try again. | If the problem continues, the code and its details. |
| NS-502 | The notification service did not confirm the removal. Notifications are not fully off. | Try again later. | If the problem continues, the code and its details. |
| NS-503 | The notification service refused the removal. Notifications are not fully off. | Try again. | If the problem continues, the code and its details. |
| NS-504 | bighelp cannot delete the notification data on your device. Notifications are not fully off. | Unlock your device. Then try again. | If the problem continues, the code and its details. |
| NS-505 | The removal stopped before it finished. | Try again. | Nothing. |

**Set Up Again** does not stop for these problems. It writes them to the device log only. Later, the app tries again, or the next setup replaces the old data:

| Code | What happened | What to do | What we need |
|---|---|---|---|
| NS-510 | bighelp cannot connect to the computer to delete its old copy. The old copy cannot send notifications. | Nothing. bighelp tries again later. | Nothing. |
| NS-511 | The notification service did not remove an old notification permission. | Nothing. bighelp tries again later. | Nothing. |
| NS-512 | bighelp cannot get the list of old notification permissions from the notification service. | Nothing. The next setup replaces them. | Nothing. |
| NS-513 | bighelp cannot clear the old setup of this computer on your device. | Nothing. The next setup replaces it. | Nothing. |

## NS-9xx: other problems

| Code | What happened | What to do | What we need |
|---|---|---|---|
| NS-901 | Something changed during setup, for example a different computer or agent, or bighelp went to the background. | Try again. | Nothing. |
| NS-902 | Setup already runs for this computer. | Wait for setup to finish. | Nothing. |
| NS-903 | bighelp found a problem in its own code. | Update bighelp. | The code and its details. |
| NS-999 | An unknown problem stopped setup. | Try again. | If the problem continues, the code and its details. |

## For people who work on bighelp

The catalog is `BighelpNotificationErrorCode` in `Bighelp/Notifications/BighelpNotificationErrorCodes.swift`.
`NotificationErrorCodeTests` makes sure that each code is unique, has a message and is on this page.
Each failure gets its code where it happens: the step and the type of error select the code.
The device log has one line for each failure: `Setup stopped: <code> at <step> (<error type>)` in subsystem `app.loopdy.mobile`, category `NotificationSetup`.

To add a code:

1. Add a new case with a new number. Do not use a number again.
2. Write its message and set `canRetry`.
3. Add a row to this page.
4. Add a test for the failure that gives the code.

To show a code on the simulator, start bighelp in demo mode with `-test-notification-failure NS-102`. Only Debug builds use this argument.
