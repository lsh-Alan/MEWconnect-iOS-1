//
//  MEWcryptoImplementation.m
//  MyEtherWallet-iOS
//
//  Created by Mikhail Nikanorov on 17/06/2018.
//  Copyright © 2018 MyEtherWallet, Inc. All rights reserved.
//

@import TrezorCrypto;

#import "MEWcryptoImplementation.h"
#import "MEWcryptoMessage.h"
#import "NSData+Hexadecimal.h"
#import "NSString+HexData.h"

static int const MEWcryptoConnectionPublicKeySize   = 65;
static int const MEWcryptoConnectionPrivateKeySize  = 32;

@interface MEWcryptoImplementation ()
@property (nonatomic, strong) NSData *connectionPrivateKey;
@property (nonatomic, strong) NSData *connectionPublicKey;
@end

@implementation MEWcryptoImplementation

- (void) configurateWithConnectionPrivateKey:(nonnull NSData *)connectionPrivateKey {
  NSParameterAssert(connectionPrivateKey);
  self.connectionPrivateKey = connectionPrivateKey;
  
  //Public key of connection
  self.connectionPublicKey = [self _publicKeyFromPrivateKey:self.connectionPrivateKey];
}

- (nullable MEWcryptoMessage *)encryptMessage:(nonnull NSData *)message {
  NSParameterAssert(self.connectionPublicKey);
  NSParameterAssert(message);
  if ([message length] == 0) {
    return nil;
  }
  NSData *ephemPrivateKeyData = nil;
  NSData *encryptionKey = nil;
  NSData *macKey = nil;
  
  /* Public data */
  NSData *ivData = nil;
  NSData *ephemPublicKeyData = nil;
  NSData *cipherData = nil;
  NSData *macData = nil;
  
  { //Preparing ephem keypair
    ephemPrivateKeyData = [self _randomDataWithLength:MEWcryptoConnectionPrivateKeySize];
    ephemPublicKeyData = [self _publicKeyFromPrivateKey:ephemPrivateKeyData];
  }
  { //Preparing initialization vector
    ivData = [self _randomDataWithLength:AES_BLOCK_SIZE];
  }
  { //Preparing encryption key & mac key
    
    uint8_t *sessionKey = malloc(sizeof(uint8_t) * MEWcryptoConnectionPublicKeySize);
    
    /* ECDH */
    ecdh_multiply(&secp256k1, ephemPrivateKeyData.bytes, self.connectionPublicKey.bytes, sessionKey);
    NSData *px = [NSData dataWithBytes:&(sessionKey[1]) length:SHA256_DIGEST_LENGTH];
    
    memset(sessionKey, 0, sizeof(uint8_t) * MEWcryptoConnectionPublicKeySize);
    free(sessionKey);
    
    /* SHA512 */
    uint8_t *digest = malloc(sizeof(uint8_t) * SHA512_DIGEST_LENGTH);
    sha512_Raw(px.bytes, sizeof(uint8_t) * SHA256_DIGEST_LENGTH, digest);
    NSData *sha512Data = [NSData dataWithBytes:digest length:sizeof(uint8_t) * SHA512_DIGEST_LENGTH];
    memset(digest, 0, sizeof(uint8_t) * SHA512_DIGEST_LENGTH);
    free(digest);
    
    /* Keys */
    encryptionKey = [sha512Data subdataWithRange:NSMakeRange(0, SHA512_DIGEST_LENGTH / 2)];
    macKey = [sha512Data subdataWithRange:NSMakeRange(SHA512_DIGEST_LENGTH / 2, SHA512_DIGEST_LENGTH / 2)];
  }
  { //Encryption
    /* Checking message alignment */
    NSMutableData *messageData = [message mutableCopy];
    
    uint8_t padding = AES_BLOCK_SIZE - ([messageData length] % AES_BLOCK_SIZE);
    if (padding == 0) {
      padding = AES_BLOCK_SIZE;
    }
    for (short i = 0; i < padding; ++i) {
      [messageData appendBytes:&padding length:sizeof(uint8_t)];
    }
    
    //buffers
    uint8_t *buffer = malloc(sizeof(uint8_t) * [messageData length]);
    uint8_t *iv = malloc(sizeof(uint8_t) * AES_BLOCK_SIZE);
    memcpy(iv, ivData.bytes, sizeof(uint8_t) * [ivData length]);
    
    /* AES-256-CBC */
    aes_encrypt_ctx context;
    aes_encrypt_key256(encryptionKey.bytes, &context);
    aes_cbc_encrypt(messageData.bytes, buffer, (int)[messageData length], iv, &context);
    
    cipherData = [NSData dataWithBytes:buffer length:[messageData length]];
    
    memset(buffer, 0, sizeof(uint8_t) * [messageData length]);
    memset(iv, 0, sizeof(uint8_t) * AES_BLOCK_SIZE);
    
    free(buffer);
    free(iv);
  }
  { //Preparing mac
    NSMutableData *dataToMac = [[NSMutableData alloc] init];
    [dataToMac appendData:ivData];
    [dataToMac appendData:ephemPublicKeyData];
    [dataToMac appendData:cipherData];
    
    uint8_t *hmac = malloc(sizeof(uint8_t) * SHA256_DIGEST_LENGTH);
    hmac_sha256(macKey.bytes, (int)[macKey length], dataToMac.bytes, (int)[dataToMac length], hmac);
    
    /* HMAC */
    macData = [NSData dataWithBytes:hmac length:sizeof(uint8_t) * SHA256_DIGEST_LENGTH];
    
    memset(hmac, 0, sizeof(uint8_t) * SHA256_DIGEST_LENGTH);
    free(hmac);
  }
  
  DDLogVerbose(@"privateKey: %@", [self.connectionPrivateKey hexadecimalString]);
  DDLogVerbose(@"publicKey: %@", [self.connectionPublicKey hexadecimalString]);
  DDLogVerbose(@"ephemPrivateKey: %@", [ephemPrivateKeyData hexadecimalString]);
  DDLogVerbose(@"ephemPublicKey: %@", [ephemPublicKeyData hexadecimalString]);
  DDLogVerbose(@"encryptionKey: %@", [encryptionKey hexadecimalString]);
  DDLogVerbose(@"macKey: %@", [macKey hexadecimalString]);
  DDLogVerbose(@"ivData: %@", [ivData hexadecimalString]);
  DDLogVerbose(@"cipherData: %@", [cipherData hexadecimalString]);
  DDLogVerbose(@"mac: %@", [macData hexadecimalString]);

  MEWcryptoMessage *cryptoMessage = [MEWcryptoMessage messageWithIV:ivData
                                                     ephemPublicKey:ephemPublicKeyData
                                                             cipher:cipherData
                                                                mac:macData];
  return cryptoMessage;
}

- (nullable NSData *)decryptMessage:(nonnull MEWcryptoMessage *)message {
  NSParameterAssert(self.connectionPrivateKey);
  NSParameterAssert(message);
  if (message.ephemPublicKey.length != MEWcryptoConnectionPublicKeySize ||
      message.iv.length != AES_BLOCK_SIZE ||
      message.mac.length != SHA256_DIGEST_LENGTH ||
      message.cipher.length == 0) {
    return nil;
  }
  
  NSData *decryptedData = nil;
  NSData *encryptionKey = nil;
  NSData *macKey = nil;
  
  { //Preparing encryption key & mac key
    
    uint8_t *sessionKey = malloc(sizeof(uint8_t) * MEWcryptoConnectionPublicKeySize);
    
    /* ECDH */
    ecdh_multiply(&secp256k1, self.connectionPrivateKey.bytes, message.ephemPublicKey.bytes, sessionKey);
    NSData *px = [NSData dataWithBytes:&(sessionKey[1]) length:SHA256_DIGEST_LENGTH];
    
    memset(sessionKey, 0, sizeof(uint8_t) * MEWcryptoConnectionPublicKeySize);
    free(sessionKey);
    
    /* SHA512 */
    uint8_t *digest = malloc(sizeof(uint8_t) * SHA512_DIGEST_LENGTH);
    sha512_Raw(px.bytes, sizeof(uint8_t) * SHA256_DIGEST_LENGTH, digest);
    NSData *sha512Data = [NSData dataWithBytes:digest length:sizeof(uint8_t) * SHA512_DIGEST_LENGTH];
    memset(digest, 0, sizeof(uint8_t) * SHA512_DIGEST_LENGTH);
    free(digest);
    
    /* Keys */
    encryptionKey = [sha512Data subdataWithRange:NSMakeRange(0, SHA512_DIGEST_LENGTH / 2)];
    macKey = [sha512Data subdataWithRange:NSMakeRange(SHA512_DIGEST_LENGTH / 2, SHA512_DIGEST_LENGTH / 2)];
  }
  
  { //Checking mac
    NSMutableData *dataToMac = [[NSMutableData alloc] init];
    [dataToMac appendData:message.iv];
    [dataToMac appendData:message.ephemPublicKey];
    [dataToMac appendData:message.cipher];
    
    uint8_t *hmac = malloc(sizeof(uint8_t) * SHA256_DIGEST_LENGTH);
    hmac_sha256(macKey.bytes, (int)[macKey length], dataToMac.bytes, (int)[dataToMac length], hmac);
    
    /* HMAC */
    NSData *macData = [NSData dataWithBytes:hmac length:sizeof(uint8_t) * SHA256_DIGEST_LENGTH];
    memset(hmac, 0, sizeof(uint8_t) * SHA256_DIGEST_LENGTH);
    free(hmac);
    
    //Compare two buffers in constant time to prevent timing attacks.
    if (![macData isEqualToData:message.mac]) {
      return nil;
    }
  }
  { //Decryption
    aes_decrypt_ctx context;
    aes_decrypt_key256(encryptionKey.bytes, &context);
    
    //buffers
    uint8_t *buffer = malloc(sizeof(uint8_t) * message.cipher.length);
    uint8_t *iv = malloc(sizeof(uint8_t) * AES_BLOCK_SIZE);
    memcpy(iv, message.iv.bytes, sizeof(uint8_t) * message.iv.length);
    
    /* AES-256-CBC */
    aes_cbc_decrypt(message.cipher.bytes, buffer, (int)message.cipher.length, iv, &context);
    
    memset(iv, 0, sizeof(uint8_t) * AES_BLOCK_SIZE);
    free(iv);
    
    decryptedData = [NSData dataWithBytes:buffer length:message.cipher.length];
    memset(buffer, 0, sizeof(uint8_t) * message.cipher.length);
    free(buffer);
    
    /* Removing alignment */
    unsigned char lastByte;
    [decryptedData getBytes:&lastByte range:NSMakeRange([decryptedData length] - 1, 1)];
    if (lastByte <= AES_BLOCK_SIZE && [decryptedData length] > lastByte) {
      BOOL cutPadding = YES;
      unsigned char *lastBytes = malloc(sizeof(unsigned char) * lastByte);
      [decryptedData getBytes:lastBytes range:NSMakeRange([decryptedData length] - lastByte, lastByte)];
      for (short i = 0; i < lastByte && cutPadding; ++i) {
        cutPadding = cutPadding && (lastBytes[i] == lastByte);
      }
      if (cutPadding) {
        decryptedData = [decryptedData subdataWithRange:NSMakeRange(0, [decryptedData length] - lastByte)];
      }
      memset(lastBytes, 0, sizeof(uint8_t) * lastByte);
      free(lastBytes);
    }
  }
  return decryptedData;
}

#pragma mark - Private

- (NSData *) _randomDataWithLength:(NSUInteger)length {
  uint8_t *buffer = malloc(sizeof(uint8_t) * length);
  random_buffer(buffer, length);
  NSData *bufferData = [NSData dataWithBytes:buffer length:sizeof(uint8_t) * length];
  memset(buffer, 0, sizeof(uint8_t) * length);
  free(buffer);
  return bufferData;
}

- (NSData *) _publicKeyFromPrivateKey:(NSData *)privateKey {
  uint8_t *publicKey = malloc(sizeof(uint8_t) * MEWcryptoConnectionPublicKeySize);
  ecdsa_get_public_key65(&secp256k1, privateKey.bytes, publicKey);
  NSData *publicKeyData = [NSData dataWithBytes:publicKey length:sizeof(uint8_t) * MEWcryptoConnectionPublicKeySize];
  memset(publicKey, 0, sizeof(uint8_t) * MEWcryptoConnectionPublicKeySize);
  free(publicKey);
  return publicKeyData;
}

@end