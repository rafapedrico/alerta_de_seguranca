/**
 * Inicialização do Firebase pro Painel de Admin — mesmo projeto
 * (guardiaox) do app e do site institucional, mesma config pública do
 * app Web já registrado (ver `website/assets/js/suporte-chat.js`, que
 * usa a mesma config). Região das callables: us-central1 — é o default
 * do Firebase quando a function não seta região explícita no código
 * (confirmado com `firebase functions:list`); só as TRIGGERS do
 * Firestore (ex: aoReceberMensagemSuporte) saem em southamerica-east1,
 * porque o Firebase co-loca elas com a região do banco.
 */
import {initializeApp} from "firebase/app";
import {getAuth} from "firebase/auth";
import {getFirestore} from "firebase/firestore";
import {getFunctions} from "firebase/functions";

const firebaseConfig = {
  projectId: "guardiaox",
  appId: "1:555863351772:web:b5766677997ffa434def19",
  storageBucket: "guardiaox.firebasestorage.app",
  apiKey: "AIzaSyA8_SqCjxlB0lhEhbF0pBf-gsJlQJ4gXgE",
  authDomain: "guardiaox.firebaseapp.com",
  messagingSenderId: "555863351772",
  measurementId: "G-7TD2NW0S3T",
};

const app = initializeApp(firebaseConfig);

export const auth = getAuth(app);
export const db = getFirestore(app);
export const functions = getFunctions(app, "us-central1");
