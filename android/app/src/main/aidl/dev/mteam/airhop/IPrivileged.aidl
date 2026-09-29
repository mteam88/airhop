package dev.mteam.airhop;

// Runs as the shell uid inside Shizuku, which holds BLUETOOTH_PRIVILEGED.
interface IPrivileged {
    void destroy() = 16777114;
    boolean connect(String address) = 1;
    boolean disconnect(String address) = 2;
    boolean setActive(String address) = 3;
    String selfAddress() = 4;
    // Raw AACP 0x31 response carrying the AirPods' IRK and advertisement key, or null.
    byte[] fetchProximityKeys(String address) = 5;
}
