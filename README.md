# OpenNotifications
 A tweak for IOS 5+ tht creates fake message and call notifications
 # How does it work?
 Hooks the Springboard bulletin system(bbserver or SBBulletinBannerController), which then posts a bulletin with the id of com.apple.MobileSMS, so it looks like a real message notification.
 # What about the call Feature?
 The tweak has its own call screen, and it uses the ringtone library to access it.
 # Requirements for install
A jailbroken iPhone on iOS 5 or later. I've only tested on iOS 6.1.3 (iPhone 4S), so treat other versions as untested.
MobileSubstrate (usually preinstalled) and PreferenceLoader from Cydia.
OpenSSH from Cydia (for the SSH method), or a file manager such as iFile (for the on-device method).
 # On device method
 1. Download the deb to your phone
 2. Use a file manager like ifile to access the copied file
 3. Locate the file and install it
 # Terminal method (No idea about windows support) 
 1. Run: scp com.opennotifications.tweak_*.deb root@PHONE_IP:/var/mobile/on.deb in the terminal. Make sure to set the PHONE_IP to the correct ip and that the package is in the right location
 2.  Run: ssh root@PHONE_IP "dpkg -i /var/mobile/on.deb; killall -9 SpringBoard" After the last command and rermber to replace PHONE_IP with the correct one.


    Questions: Email me at bobchtus@gmail.com
