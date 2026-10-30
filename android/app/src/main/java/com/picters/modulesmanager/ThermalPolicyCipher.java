package com.picters.modulesmanager;

import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** In-memory Xiaomi policy codec. Does not access files, root or thermal services. */
public final class ThermalPolicyCipher {
    private static final int MAX_BYTES = 2 * 1024 * 1024;
    private static final byte[] LEGACY = "thermalopenssl.h".getBytes(StandardCharsets.US_ASCII);
    // Thermal file-format key recovered from the verified pudding loader; not a signing key.
    private static final byte[] ODM = fromHex("6bc1bee22e409f96e93d7e117393172a");

    public static final class Decoded {
        public final String text;
        public final String codec;
        private Decoded(String text, String codec) { this.text = text; this.codec = codec; }
    }

    private static byte[] fromHex(String hex) {
        byte[] result = new byte[hex.length() / 2];
        for (int i = 0; i < result.length; i++) {
            result[i] = (byte) Integer.parseInt(hex.substring(i * 2, i * 2 + 2), 16);
        }
        return result;
    }

    private static byte[] key(String codec) {
        if ("legacy".equals(codec)) return LEGACY;
        if ("pudding-odm".equals(codec)) return ODM;
        throw new IllegalArgumentException("Unsupported thermal codec");
    }

    private static byte[] crypt(byte[] bytes, String codec, int operation)
            throws GeneralSecurityException {
        if (bytes.length > MAX_BYTES) throw new IllegalArgumentException("Policy too large");
        byte[] key = key(codec);
        Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
        cipher.init(operation, new SecretKeySpec(key, "AES"), new IvParameterSpec(key));
        return cipher.doFinal(bytes);
    }

    private static String strictText(byte[] bytes) throws Exception {
        String text = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString();
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if ((c < 32 && c != '\n' && c != '\r' && c != '\t') || c == 127) {
                throw new IllegalArgumentException("Invalid thermal text");
            }
        }
        String trimmed = text.trim();
        if (!trimmed.isEmpty() && !trimmed.startsWith("[") && !trimmed.startsWith("#")) {
            throw new IllegalArgumentException("Unknown thermal syntax");
        }
        return text;
    }

    public static Decoded decode(byte[] bytes) throws Exception {
        if (bytes.length > MAX_BYTES) throw new IllegalArgumentException("Policy too large");
        // Plaintext files exist alongside encrypted stock policies.
        try { return new Decoded(strictText(bytes), "plaintext"); }
        catch (Exception ignored) { }
        for (String codec : new String[]{"legacy", "pudding-odm"}) {
            try {
                byte[] plain = crypt(bytes, codec, Cipher.DECRYPT_MODE);
                String text = strictText(plain);
                if (!java.util.Arrays.equals(crypt(plain, codec, Cipher.ENCRYPT_MODE), bytes)) {
                    continue;
                }
                return new Decoded(text, codec);
            } catch (Exception ignored) { }
        }
        throw new IllegalArgumentException("Thermal policy could not be decoded");
    }

    public static byte[] encode(String text, String codec) throws Exception {
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        strictText(bytes);
        byte[] encrypted = crypt(bytes, codec, Cipher.ENCRYPT_MODE);
        if (!java.util.Arrays.equals(crypt(encrypted, codec, Cipher.DECRYPT_MODE), bytes)) {
            throw new GeneralSecurityException("Thermal codec verification failed");
        }
        return encrypted;
    }
}
